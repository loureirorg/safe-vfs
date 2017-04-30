require 'rfusefs'
require 'safenet'
require 'tempfile'
require 'digest'
require 'date'

VERSION = "0.2.0"

module RFuse
  class Stat
    def self.symlink(mode=0,values = { })
      return self.new(S_IFLNK,mode,values)
    end
  end
end

module FuseFS
  class Fuse < RFuse::FuseDelegator
    class Root
      def symlink(ctx, path, as)
        return wrap_context(ctx,__method__,path,as) if ctx
        raise Errno::ENOSYS if ! @root.respond_to?(:symlink)
        @root.symlink(path, as)
      end

      def readlink(ctx, path, size)
        return wrap_context(ctx,__method__,path, size) if ctx
        raise Errno::ENOSYS if ! @root.respond_to?(:readlink)
        @root.readlink(path, size)
      end

      def getattr(ctx,path)

        return wrap_context(ctx,__method__,path) if ctx

        uid = Process.uid
        gid = Process.gid

        if  path == "/" || @root.directory?(path)
          #set "w" flag based on can_mkdir? || can_write? to path + "/._rfuse_check"
          write_test_path = (path == "/" ? "" : path) + CHECK_FILE

          mode = (@root.can_mkdir?(write_test_path) || @root.can_write?(write_test_path)) ? 0777 : 0555
          atime,mtime,ctime = @root.times(path)
          #nlink is set to 1 because apparently this makes find work.
          return RFuse::Stat.directory(mode,{ :uid => uid, :gid => gid, :nlink => 1, :atime => atime, :mtime => mtime, :ctime => ctime })
        elsif @created_files.has_key?(path)
          return @created_files[path]
        elsif @root.file?(path)
          #Set mode from can_write and executable
          mode = 0444
          mode |= 0222 if @root.can_write?(path)
          mode |= 0111 if @root.executable?(path)
          size = size(path)
          atime,mtime,ctime = @root.times(path)
          if @root.respond_to?(:symlink?) && @root.symlink?(path)
            return RFuse::Stat.symlink(mode,{ :nlink => 1, :uid => uid, :gid => gid, :size => size, :atime => atime, :mtime => mtime, :ctime => ctime })
          else
            return RFuse::Stat.file(mode,{ :uid => uid, :gid => gid, :size => size, :atime => atime, :mtime => mtime, :ctime => ctime })
          end
        else
          raise Errno::ENOENT.new(path)
        end

      end #getattr

    end
  end
end

class CacheTree
  def initialize
    # "Invalid" means cache needs to be updated
    @cached = {folders: {}, files: {}, symlinks: {}, valid: false}
  end

  def find_folder(path)
    folders = path.split('/')
    folders.shift if folders.any? && (folders.first == '') # 1st item is blank if path starts with "/"
    current = @cached
    while folder = folders.shift
      hash_name = Digest::SHA2.new(256).hexdigest(folder)
      if ! current[:folders].key?(hash_name)
        current[:folders][hash_name] = {folders: {}, files: {}, symlinks: {}, valid: false}
      end
      current = current[:folders][hash_name]
    end

    current
  end

  # Adds an entry
  #   ex.: put(true, '/a/b', 'my_file', {name: 'my_file', is_private: true, ...})
  #   entries: {hash_name: {is_file: ..., name: ..., ...}, }
  def put(type = 'file', path, name, item)

    # init subfolder info
    if type == 'folder'
      item[:folders]  = {}
      item[:files]    = {}
      item[:symlinks] = {}
      item[:valid]    = false
    end

    # go to the correct folder
    current = find_folder(path)

    # working list
    entries = case type
    when 'file' then current[:files]
    when 'folder' then current[:folders]
    when 'symlink' then current[:symlinks]
    end

    # add entry
    hash_name = Digest::SHA2.new(256).hexdigest(name)
    entries[hash_name] = item

    item
  end

  # Ex.: get(true, '/a/b', 'my_file')
  def get(type, path, name)
    # go to the correct folder
    current = find_folder(path)

    # working list
    entries = case type
    when 'file' then current[:files]
    when 'folder' then current[:folders]
    when 'symlink' then current[:symlinks]
    end

    # entry
    hash_name = Digest::SHA2.new(256).hexdigest(name)
    entries[hash_name]
  end
end

class SafeVFS
  def initialize
    # Keeps the structure in cache for speed up
    #   Cache is only used to display time/size/directory?/file?
    #   ls/cat DO NOT use cache
    $cached_private = CacheTree.new
    $cached_public  = CacheTree.new
    $cached_alien   = CacheTree.new
    $cached_dns     = CacheTree.new

    @safe = SafeNet::Client.new({
      name: 'SAFE Virtual FS',
      version: VERSION,
      vendor: 'Daniel Loureiro',
      id: 'safe-vfs',
      permissions: ['SAFE_DRIVE_ACCESS']
    })

    @safe.nfs.delete_file('settings.json', root_path: 'app', is_private: true)
    @settings = @safe.nfs.get_file('settings.json', root_path: 'app', is_private: true)['body']
    if @settings.nil?
      default_structure = {
        alien_items: []
      }
      @safe.nfs.create_file('settings.json', default_structure.to_json, root_path: 'app', is_private: true)
      @settings = @safe.nfs.get_file('settings.json', root_path: 'app', is_private: true)['body']
    end
    @settings = JSON.parse(@settings)
  end

  def cache(root_type)
    case root_type
    when 'public'  then $cached_public
    when 'private' then $cached_private
    when 'others'  then $cached_alien
    when 'dns'     then $cached_dns
    else raise Errno::EBADF
    end
  end

  def split_path(path)
    cur, *rest = path.scan(/[^\/]+/)
    if rest.empty?
      [ cur, nil ]
    else
      [ cur, File::SEPARATOR + File.join(rest) ]
    end
  end

  def scan_path(path)
    path.scan(/[^\/]+/)
  end

  def contents(path)
    folders = path.split('/')
    folders.shift # 1st item is always blank
    if folders.empty? # path == '/'
      return ['public', 'private', 'others', 'dns']
    end

    root_type = folders.shift # public / private / others
    path = '/' + folders.join('/') # relative to /public or /private
    path.squeeze!('/')

    case root_type
    when 'dns'
      # puts 'DNS'
      # puts "path: #{path}"
      # puts "folders: #{folders.join('.')}"
      # invalidates cache
      cache = $cached_alien.find_folder(path)
      cache[:folders] = {}
      cache[:files] = {}
      cache[:symlinks] = {}
      cache[:valid] = true

      if path == '/'
        items = @safe.dns.list_long_names
        items.each do |item|
          $cached_dns.put('folder', '/', item, {'name' => item})
        end
        return items

      else
        name, path = split_path(path)
        items = @safe.dns.list_services(name)
        items.each do |item|
          $cached_dns.put('symlink', "/#{name}", item, {'name' => item, 'size' => "#{PWD}/public/#{item}".length})
        end
        return items
      end
    when 'others'
      if folders.empty? # root, ie. "ls /others"
        return @settings["alien_items"]

      else # "ls /others/www.something"
        folders.shift if folders.first == ''
        if folders.length == 1
          domain_items = folders.pop.split('.')
          raise Errno::EBADF if domain_items.length != 2 # invalid format. It should be "<service_name>.<long_name>"

          # invalidates cache
          cache = $cached_alien.find_folder(path)
          cache[:folders] = {}
          cache[:files] = {}
          cache[:symlinks] = {}
          cache[:valid] = true

          # list of files/dirs
          safe_res = @safe.dns.get_home_dir(domain_items[1], domain_items[0])

          # files
          safe_res['files'].each do |item|
            $cached_alien.put('file', path, item['name'], item)
          end

          # folders
          safe_res['subDirectories'].each do |item|
            $cached_alien.put('folder', path, item['name'], item)
          end

          # validates cache
          $cached_alien.find_folder(path)[:valid]  = true

          # returns list of files / directories
          entries = $cached_alien.find_folder(path)
          return (entries[:folders].values + entries[:files].values).map {|i| i['name']}
        else
          raise Errno::EPERM # we cannot read subfolders
        end
      end

    when 'public', 'private'
      # Safe DOESN'T have a /public and a /private folders,
      #  instead all private and public items are mixed together on root.
      #  For a /public  emulation, it checks on "/" for isPrivate=false items
      #  For a /private emulation, it checks on "/" for isPrivate=true  items
      safe_res = @safe.nfs.get_directory(path, root_path: root_type == 'public' ? 'app' : 'drive')
      return [] if safe_res['errorCode']

      # invalidates cache
      cache = $cached_private.find_folder(path)
      cache[:folders]  = {}
      cache[:files]    = {}
      cache[:symlinks] = {}

      cache = $cached_public.find_folder(path)
      cache[:folders]  = {}
      cache[:files]    = {}
      cache[:symlinks] = {}

      # files
      cache = safe_res['info']['isPrivate'] ? $cached_private : $cached_public
      safe_res['files'].each do |item|
        # symlinks start with either ".SAFE_SYMLINK_PUBLIC." or ".SAFE_SYMLINK."
        if item['name'].start_with?('.SAFE_SYMLINK')
          if item['name'].start_with?('.SAFE_SYMLINK_PUBLIC.')
            cache = $cached_public
            item['name'] = item['name'][21..-1]
          else
            item['name'] = item['name'][14..-1]
          end
          cache.put('symlink', path, item['name'], item)
        else
          cache.put('file', path, item['name'], item)
        end
      end

      # folders
      safe_res['subDirectories'].each do |item|
        cache = item['isPrivate'] ? $cached_private : $cached_public
        cache.put('folder', path, item['name'], item)
      end

      # validates cache
      $cached_private.find_folder(path)[:valid] = true
      $cached_public.find_folder(path)[:valid]  = true

      # returns list of files / directories
      entries = case root_type
      when 'public' then $cached_public.find_folder(path)
      when 'private' then $cached_private.find_folder(path)
      end

      (entries[:folders].values + entries[:files].values + entries[:symlinks].values).map {|i| i['name']}
    end
  end

  def get_entries(path)
    folders = path.split('/')
    folders.shift # 1st item is always blank
    name = folders.pop
    return false if folders.empty? # /, /public, /private

    root_type = folders.shift
    path = '/' + folders.join('/') # relative to /public or /private

    # Cache
    cached = cache(root_type)

    entries = cached.find_folder(path)
    if ! entries[:valid]
      contents("/#{root_type}/#{path}")
      entries = cached.find_folder(path)
    end
    hash_name = Digest::SHA2.new(256).hexdigest(name)
    {name: name, hash_name: hash_name, path: path, entries: entries}
  end

  def get_file_entry(path)
    _ = get_entries(path)
    if _
      hash_name = _[:hash_name]
      entries   = _[:entries]
      return entries[:files][hash_name]
    end
    return nil
  end

  def get_symlink_entry(path)
    _ = get_entries(path)
    if _
      hash_name = _[:hash_name]
      entries   = _[:entries]
      return entries[:symlinks][hash_name]
    end
    return nil
  end

  def get_folder_entry(path)
    _ = get_entries(path)
    if _
      hash_name = _[:hash_name]
      entries   = _[:entries]
      return entries[:folders][hash_name]
    end
    return nil
  end

  def rename(from_path, to_path)
    # puts "rename: #{from_path} #{to_path}"
    is_link = symlink?(from_path)
    is_directory = directory?(from_path)

    # path items
    from_root_type, from_path = split_path(from_path)
    path_items = scan_path(from_path)
    from_name = path_items.pop
    from_path = '/' + path_items.join('/')
    if is_link
      from_name = from_root_type == 'public' ? ".SAFE_SYMLINK_PUBLIC.#{from_name}" : ".SAFE_SYMLINK.#{from_name}"
    end

    to_root_type, to_path = split_path(to_path)
    path_items = scan_path(to_path)
    to_name = path_items.pop
    to_path = '/' + path_items.join('/')
    if is_link
      to_name = to_root_type == 'public' ? ".SAFE_SYMLINK_PUBLIC.#{to_name}" : ".SAFE_SYMLINK.#{to_name}"
    end

    raise Errno::EBADF if to_root_type != from_root_type # move from priv to pub: not implemented yet

    # check if is there a folder with the same name in /public
    if is_directory
      if to_root_type == 'public'
        raise Errno::EPERM.new("There's a folder with the same name in /public") if directory?("/private/#{to_path}/#{to_name}".squeeze('/'))
      else
        raise Errno::EPERM.new("There's a folder with the same name in /private") if directory?("/public/#{to_path}/#{to_name}".squeeze('/'))
      end
    end

    from_root_path = from_root_type == 'public' ? 'app' : 'drive'
    to_root_path   = to_root_type   == 'public' ? 'app' : 'drive'
    @safe.nfs.move_file(from_root_path, "#{from_path}/#{from_name}".squeeze('/'), to_root_path, to_path, 'move') if from_path != to_path
    @safe.nfs.update_file_meta("#{from_path}/#{from_name}".squeeze('/'), root_path: from_root_path, name: to_name) if ! is_directory && (to_name != from_name)
    @safe.nfs.update_directory("#{from_path}/#{from_name}".squeeze('/'), root_path: from_root_path, name: to_name) if is_directory && (to_name != from_name)

    # invalidates cache
    from = "/#{from_root_type}/#{from_path}".squeeze('/')
    to = "/#{to_root_type}/#{to_path}".squeeze('/')

    cached = cache(from_root_type)
    entries = cached.find_folder(from)
    entries[:valid] = false
    contents(from)

    if from != to
      cached = cache(to_root_type)
      entries = cached.find_folder(to)
      entries[:valid] = false
      contents(to) if from != to
    end

    true
  end

  def touch(path, modtime)
    folders = path.split('/')
    folders.shift # remove blank
    root_type = folders.shift
    path = '/' + folders.join('/') # relative to /public or /private

    raise Errno::EPERM if (root_type != 'private') || (root_type != 'public') # 'others' is not allowed

    @safe.nfs.create_file(
      path,
      "\n", # SAFE bug!!!
      root_path: root_type == 'public' ? 'app' : 'drive',
      is_private: root_type == 'private'
    )
  end

  def file?(path)
    # puts "FILE? #{path} #{path == '/private/Link to logo-min.png'} #{!(get_file_entry(path).nil? && get_symlink_entry(path).nil?)}"
    return ! (get_file_entry(path).nil? && get_symlink_entry(path).nil?)
  end

  def symlink?(path)
    # puts "SYMLINK? #{path} #{path == '/private/Link to logo-min.png'} #{!get_symlink_entry(path).nil?}"
    return ! get_symlink_entry(path).nil?
  end

  def times(path)
    # puts "times #{path}"
    file = get_file_entry(path)
    file = get_folder_entry(path) if ! file
    return [0, 0, 0] if ! file

    begin
    [
      DateTime.rfc3339(file['modifiedOn']).to_time.to_i,
      DateTime.rfc3339(file['modifiedOn']).to_time.to_i,
      DateTime.rfc3339(file['createdOn']).to_time.to_i
    ]
    rescue
      return [0, 0, 0]
    end
  end

  def directory?(path)
    folders = path.split('/')
    folders.shift # 1st item is always blank
    name = folders.pop
    return true if folders.empty? # /, /public, /private

    root_type = folders.shift
    path = '/' + folders.join('/') # relative to /public or /private

    # Cache
    cached = cache(root_type)

    # Cache
    entries = cached.find_folder(path)
    contents("/#{root_type}/#{path}") if ! entries[:valid]
    hash_name = Digest::SHA2.new(256).hexdigest(name)
    return entries[:folders].key?(hash_name)
  end

  def can_mkdir?(path)
    # CANNOT create folders/files at root
    path != '/'
  end

  def can_rmdir?(path)
    # CANNOT destroy folders/files at root
    path != '/'
  end

  def mkdir(path)
    raise Errno::EPERM if path == '/'

    folders = path.split('/')
    folders.shift # 1st item is always blank
    name = folders.pop

    root_type = folders.shift
    path = '/' + folders.join('/') # relative to /public or /private
    path = path + '/' if folders.any?

    # Cache
    cached = cache(root_type)

    path = path + name
    if root_type == 'others'
      raise Errno::EPERM if folders.any? # you can only create dirs at /others, not on its subfolders

      # domain exists?
      domain_items = name.split('.')
      if @safe.dns.get_home_dir(domain_items[1], domain_items[0])['errorCode']
        raise Errno::ENOENT
      end

      @settings["alien_items"] << name
      @safe.nfs.delete_file('settings.json', root_path: 'app', is_private: true)
      @safe.nfs.create_file('settings.json', @settings.to_json, root_path: 'app', is_private: true)
      @settings = @safe.nfs.get_file('settings.json', root_path: 'app', is_private: true)['body']
      @settings = JSON.parse(@settings)
      contents("/#{root_type}#{path}")
    else
      @safe.nfs.create_directory(path, root_path: root_type == 'public' ? 'app' : 'drive', is_private: root_type == 'private')
    end

    # invalidates cache
    entries = cached.find_folder(path)
    entries[:valid] = false

    true
  end

  def rmdir(path)
    raise Errno::EPERM if path == '/'

    folders = path.split('/')
    folders.shift # 1st item is always blank
    name = folders.pop

    root_type = folders.shift
    path = '/' + folders.join('/') # relative to /public or /private
    path = path + '/' if folders.any?

    path = path + name

    # Cache
    cached = cache(root_type)

    if root_type == 'others'
      # remove from settings.json
      @settings["alien_items"] = @settings["alien_items"] - [name]
      @safe.nfs.delete_file('settings.json', root_path: 'app', is_private: true)
      @safe.nfs.create_file('settings.json', @settings.to_json, root_path: 'app', is_private: true)
      @settings = @safe.nfs.get_file('settings.json', root_path: 'app', is_private: true)['body']
      @settings = JSON.parse(@settings)
    else
      # CANNOT destroy if there are files inside
      entries = cached.find_folder(path)
      contents("/#{root_type}/#{path}") if ! entries[:valid]
      raise Errno::ENOTEMPTY if entries[:files].any?

      @safe.nfs.delete_directory(
        path,
        root_path: root_type == 'public' ? 'app' : 'drive',
        is_private: root_type == 'private'
      )
    end

    # invalidates cache
    entries[:valid] = false

    true
  end

  def can_write?(path)
    folders = path.split('/')
    folders.shift # 1st item is always blank
    root_type = folders.shift
    (root_type == 'public') || (root_type == 'private')
  end

  def can_delete?(path)
    folders = path.split('/')
    folders.shift # 1st item is always blank
    root_type = folders.shift
    (root_type == 'public') || (root_type == 'private')
  end

  def delete(path)
    is_link = symlink?(path)

    # path items
    root_type, path = split_path(path)
    path_items = scan_path(path)
    name = path_items.pop
    path = '/' + path_items.join('/')

    if is_link
      name = root_type == 'public' ? ".SAFE_SYMLINK_PUBLIC.#{name}" : ".SAFE_SYMLINK.#{name}"
    end

    @safe.nfs.delete_file("#{path}/#{name}".squeeze('/'), root_path: root_type == 'public' ? 'app' : 'drive', is_private: root_type == 'private')
  end

  def raw_open(path, mode, raw=nil)
    # puts "raw_open #{path}"
    folders = path.split('/')
    folders.shift # 1st item is always blank
    name = folders.pop

    root_type = folders.shift
    path = '/' + folders.join('/') # relative to /public or /private

    # read-only mode "/others"
    if (root_type == 'others') && ['w', 'rw', 'a'].include?(mode)
      raise Errno::EPERM.new('Read-only folder')
    end

    # root of "/public" is for folders only (not files)
    if (root_type == 'public') && ['w', 'rw', 'a'].include?(mode) && (path == '/')
      raise Errno::EPERM.new('Public folder can only contain subfolders')
    end

    # long_name, service_name
    domain_items = []
    if root_type == 'others'
      domain = folders.shift
      domain_items = domain.split('.')
      raise Errno::EBADF if domain_items.length != 2 # Bad format
      path = '/' + folders.join('/') # relative to /public or /private
    end

    # Write mode: SAFE lacks support for updating files
    #  Workaround: save contents in a local temp file and send it to the
    #  network in raw_close
    tmp_hnd = Tempfile.new('safe')
    tmp_hnd.binmode # binary mode

    {
      path: path,
      mode: mode,
      name: name,
      root_type: root_type,
      tmp_hnd: tmp_hnd,
      service_name: domain_items[0],
      long_name: domain_items[1],
      contents_changed: false,
      contents_loaded: false # for rw mode, we need to load the entire file if we want to change it
    }
  end

  def raw_read(path, offset, size, raw)
    # puts "raw_read: #{path}"
    # offset / length not implemented yet on SAFE
    if ! raw[:contents_loaded]
      file = if raw[:root_type] == 'others'
        @safe.dns.get_file_unauth(
          raw[:long_name],
          raw[:service_name],
          [raw[:path], raw[:name]].join('/')
        )
      else
        @safe.nfs.get_file(
          [raw[:path], raw[:name]].join('/'),
          root_path: 'drive',
          is_private: raw[:root_type] == 'private'
        )
      end
      raise Errno::ENOENT if file['body'].nil?

      raw[:tmp_hnd].seek(0)
      raw[:tmp_hnd].write(file["body"]) if file['body']
      raw[:contents_loaded] = true
    end

    raw[:tmp_hnd].seek(0)
    return File.binread(raw[:tmp_hnd], size, offset)
  end

  def raw_write(path, offset, size, buffer, raw)
    # puts "raw_write: #{path}"
    raise Errno::EPERM if ! ['w', 'rw', 'a'].include?(raw[:mode]) # read-only mode

    # write and read mode, we need load the file
    if (raw[:mode] == 'rw' || raw[:mode] == 'a') && (raw[:contents_loaded] == false)
      raw[:contents_loaded] = true
      file = @safe.nfs.get_file(
        [raw[:path], raw[:name]].join('/'),
        root_path: 'drive',
        is_private: raw[:root_type] == 'private'
      )
      raw[:tmp_hnd].seek(0)
      raw[:tmp_hnd].write(file['body']) if file['body']
    end

    raw[:contents_changed] = true
    raw[:tmp_hnd].seek(offset)
    raw[:tmp_hnd].write(buffer)
  end

  def raw_close(path, raw)
    # puts "raw_close: #{path}"
    # write mode, create file if necessary, freed resources
    if raw[:tmp_hnd] && raw[:contents_changed]
      @safe.nfs.delete_file([raw[:path], raw[:name]].join('/'), root_path: 'drive')
      raw[:tmp_hnd].seek(0)
      contents = raw[:tmp_hnd].read
      contents ||= "\n" # SAFE bug
      @safe.nfs.create_file([raw[:path], raw[:name]].join('/'), contents, root_path: 'drive')

      # invalidates cache
      cached = cache(raw[:root_type])
      entries = cached.find_folder(raw[:path])
      entries[:valid] = false
      contents("/#{raw[:root_type]}/#{raw[:path]}".squeeze('/'))

    elsif raw[:tmp_hnd]
      contents = raw[:tmp_hnd].read
      if contents.empty? # SAFE bug
        contents = "\n"
        @safe.nfs.create_file([raw[:path], raw[:name]].join('/'), contents, root_path: 'drive')

        # invalidates cache
        cached = cache(raw[:root_type])
        entries = cached.find_folder(raw[:path])
        entries[:valid] = false
        contents("/#{raw[:root_type]}/#{raw[:path]}".squeeze('/'))
      end
    end

    if raw[:tmp_hnd]
      raw[:tmp_hnd].close
    end
  end

  def symlink(from, to)
    # puts "SYMLINK #{from} -> #{to} #{PWD}"
    from = from[PWD.length..-1] # absolute path
    root_type, to = split_path(to)
    raise Errno::EPERM if ! ['public', 'private', 'dns'].include?(root_type)

    path_items = scan_path(to)
    name = path_items.pop
    path = '/' + path_items.join('/')

    # save on network
    link_name = root_type == 'public' ? ".SAFE_SYMLINK_PUBLIC.#{name}" : ".SAFE_SYMLINK.#{name}"
    @safe.nfs.create_file(link_name, from, root_path: root_type == 'public' ? 'app' : 'drive', is_private: root_type == 'private')

    # save on cache
    cached = cache(root_type)
    entries = cached.find_folder(path)
    entries[:valid] = false
  end

  def readlink(path, size)
    # puts "READ SYMLINK #{path} #{size}"
    root_type, path = split_path(path)
    path_items = scan_path(path)
    name = path_items.pop
    path = '/' + path_items.join('/')

    if root_type == 'dns'
      safe_res = @safe.dns.get_home_dir(path_items.first, name)
      return "#{PWD}/public/#{safe_res['info']['name']}"
    end

    link_name = root_type == 'public' ? ".SAFE_SYMLINK_PUBLIC.#{name}" : ".SAFE_SYMLINK.#{name}"
    PWD + @safe.nfs.get_file("#{path}/#{link_name}".squeeze('/'), root_path: root_type == 'public' ? 'app' : 'drive', is_private: root_type == 'private')['body']
  end

  def size(path)
    # puts "SIZE: #{path}"
    file = get_file_entry(path)
    file = get_symlink_entry(path) if ! file

    raise Errno::ENOENT if file.nil?
    return file['size']
  end
end

safe_vfs = SafeVFS.new
# safe_vfs.contents('/')
# PWD = '/home/daniel/safe-disk'
# FuseFS.start(safe_vfs, '/home/daniel/safe-disk')
PWD = ARGV[0]
FuseFS.main() { |opt| safe_vfs }
