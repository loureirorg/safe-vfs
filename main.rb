require 'rfusefs'
require 'safenet'
require 'tempfile'
require 'digest'
require 'date'

VERSION = "1.4.0"

class CacheTree
  def initialize
    # "Invalid" means cache needs to be updated
    @cached = {folders: {}, files: {}, valid: false}
  end

  def find_folder(path)
    folders = path.split('/')
    folders.shift if folders.any? && (folders.first == '') # 1st item is blank if path starts with "/"
    current = @cached
    while folder = folders.shift
      hash_name = Digest::SHA2.new(256).hexdigest(folder)
      if ! current[:folders].key?(hash_name)
        current[:folders][hash_name] = {folders: {}, files: {}, valid: false}
      end
      current = current[:folders][hash_name]
    end

    current
  end

  # Adds an entry
  #   ex.: put(true, '/a/b', 'my_file', {name: 'my_file', is_private: true, ...})
  #   entries: {hash_name: {is_file: ..., name: ..., ...}, }
  def put(is_file, path, name, item)

    # init subfolder info
    if ! is_file
      item[:folders] = {}
      item[:files]   = {}
      item[:valid]   = false
    end

    # go to the correct folder
    current = find_folder(path)

    # add entry
    entries = is_file ? current[:files] : current[:folders] # working list
    hash_name = Digest::SHA2.new(256).hexdigest(name)
    entries[hash_name] = item

    item
  end

  # Ex.: get(true, '/a/b', 'my_file')
  def get(is_file, path, name)
    # go to the correct folder
    current = find_folder(path)

    # entry
    entries = is_file ? current[:files] : current[:folders] # working list
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

    @safe = SafeNet::Client.new({
      name: 'SAFE Virtual FS',
      version: '0.1.0',
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

  def contents(path)
    folders = path.split('/')
    folders.shift # 1st item is always blank
    if folders.empty? # path == '/'
      return ['public', 'private', 'outside']
    end

    root_type = folders.shift # public / private / outside
    path = '/' + folders.join('/') # relative to /public or /private
    path.squeeze!('/')

    if root_type == 'outside'
      if folders.empty? # root, ie. "ls /outside"
        return @settings["alien_items"]

      else # "ls /outside/www.something"
        folders.shift if folders.first == ''
        if folders.length == 1
          domain_items = folders.pop.split('.')
          raise Errno::EBADF if domain_items.length != 2 # invalid format. It should be "<service_name>.<long_name>"

          # invalidates cache
          cache = $cached_alien.find_folder(path)
          cache[:folders] = {}
          cache[:files] = {}

          # list of files/dirs
          safe_res = @safe.dns.get_home_dir(domain_items[1], domain_items[0])

          # files
          safe_res['files'].each do |item|
            $cached_alien.put(true, path, item['name'], item)
          end

          # folders
          safe_res['subDirectories'].each do |item|
            $cached_alien.put(false, path, item['name'], item)
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

    # /public or /private
    else
      root_is_public = (root_type == 'public')

      # Safe DOESN'T have a /public and a /private folders,
      #  instead all private and public items are mixed together on root.
      #  For a /public  emulation, it checks on "/" for isPrivate=false items
      #  For a /private emulation, it checks on "/" for isPrivate=true  items
      safe_res = @safe.nfs.get_directory(path, root_path: 'drive')
      return [] if safe_res['errorCode']

      # invalidates cache
      cache = $cached_private.find_folder(path)
      cache[:folders] = {}
      cache[:files] = {}
      cache = $cached_public.find_folder(path)
      cache[:folders] = {}
      cache[:files] = {}

      # files
      cache = safe_res['info']['isPrivate'] ? $cached_private : $cached_public
      safe_res['files'].each do |item|
        cache.put(true, path, item['name'], item)
      end

      # folders
      safe_res['subDirectories'].each do |item|
        cache = item['isPrivate'] ? $cached_private : $cached_public
        cache.put(false, path, item['name'], item)
      end

      # validates cache
      $cached_private.find_folder(path)[:valid] = true
      $cached_public.find_folder(path)[:valid]  = true

      # returns list of files / directories
      entries = root_is_public ? $cached_public.find_folder(path) : $cached_private.find_folder(path)
      (entries[:folders].values + entries[:files].values).map {|i| i['name']}
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
    cached = case root_type
    when 'public' then $cached_public
    when 'private' then $cached_private
    when 'outside' then $cached_alien
    else raise Errno::EBADF
    end

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
    # remove "/private" or "/public": it doesn't matter
    folders = from_path.split('/')
    folders.shift # blank
    priv_pub_from = folders.shift # private or public
    name_from = folders.pop # file name
    folders << name_from
    from_path = ([''] + folders).join('/')

    # remove "/private" or "/public": it doesn't matter
    folders = to_path.split('/')
    folders.shift # blank
    priv_pub_to = folders.shift # private or public
    name_to = folders.pop # file name
    to_path = ([''] + folders).join('/')

    raise Errno::EBADF if priv_pub_from != priv_pub_to # move from priv to pub: not implemented yet

    @safe.nfs.move_file('drive', from_path, 'drive', to_path, 'move')
    @safe.nfs.update_file_meta([to_path, name_from].join('/'), root_path: 'drive', name: name_to) if name_to != name_from
    @safe.nfs.update_directory([to_path, name_from].join('/'), root_path: 'drive', name: name_to) if name_to != name_from

    # Cache
    cached = case priv_pub_from
    when 'public' then $cached_public
    when 'private' then $cached_private
    when 'outside' then $cached_alien
    else raise Errno::EBADF
    end

    # invalidates cache
    entries = cached.find_folder("/#{priv_pub_from}/#{from_path}")
    entries[:valid] = false

    contents("/#{priv_pub_from}/#{from_path}")
    contents("/#{priv_pub_to}/#{to_path}")

    true
  end

  def touch(path, modtime)
    folders = path.split('/')
    folders.shift # remove blank
    root_type = folders.shift
    path = '/' + folders.join('/') # relative to /public or /private

    raise Errno::EPERM if (root_type != 'private') || (root_type != 'public') # 'outside' is not allowed

    @safe.nfs.create_file(
      path,
      "\n", # SAFE bug!!!
      root_path: 'drive',
      is_private: root_type == 'private'
    )
  end

  def file?(path)
    return ! get_file_entry(path).nil?
  end

  def times(path)
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
    cached = case root_type
    when 'public' then $cached_public
    when 'private' then $cached_private
    when 'outside' then $cached_alien
    else raise Errno::EBADF
    end

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
    cached = case root_type
    when 'public' then $cached_public
    when 'private' then $cached_private
    when 'outside' then $cached_alien
    else raise Errno::EBADF
    end

    path = path + name
    if root_type == 'outside'
      raise Errno::EPERM if folders.any? # you can only create dirs at /outside, not on its subfolders

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
      @safe.nfs.create_directory(path, root_path: 'drive', is_private: root_type == 'private')
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
    cached = case root_type
    when 'public' then $cached_public
    when 'private' then $cached_private
    when 'outside' then $cached_alien
    else raise Errno::EBADF
    end

    if root_type == 'outside'
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

      @safe.nfs.delete_directory(path, root_path: 'drive', is_private: root_type == 'private')
    end

    # invalidates cache
    entries[:valid] = false

    true
  end

  def can_write?(path)
    folders = path.split('/')
    folders.shift # 1st item is always blank
    priv_pub = folders.shift
    (priv_pub == 'public') || (priv_pub == 'private')
  end

  def can_delete?(path)
    folders = path.split('/')
    folders.shift # 1st item is always blank
    priv_pub = folders.shift
    (priv_pub == 'public') || (priv_pub == 'private')
  end

  def delete(path)
    folders = path.split('/')
    folders.shift # 1st item is always blank
    priv_pub = folders.shift

    @safe.nfs.delete_file(folders.join('/'), root_path: 'drive', is_private: priv_pub == 'private')
  end

  def raw_open(path, mode, raw=nil)
    folders = path.split('/')
    folders.shift # 1st item is always blank
    name = folders.pop

    root_type = folders.shift
    path = '/' + folders.join('/') # relative to /public or /private

    # read-only mode "/outside"
    raise Errno::EPERM if (root_type == 'outside') && ['w', 'rw', 'a'].include?(mode)

    # root of "/public" is for folders only (not files)
    raise Errno::EPERM if (root_type == 'public') && ['w', 'rw', 'a'].include?(mode) && (path == '/')

    # long_name, service_name
    domain_items = []
    if root_type == 'outside'
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
    # offset / length not implemented yet on SAFE
    if ! raw[:contents_loaded]
      file = if raw[:root_type] == 'outside'
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
    # write mode, create file if necessary, freed resources
    if raw[:tmp_hnd] && raw[:contents_changed]
      @safe.nfs.delete_file([raw[:path], raw[:name]].join('/'), root_path: 'drive', is_private: raw[:root_type] == 'private')
      raw[:tmp_hnd].seek(0)
      contents = raw[:tmp_hnd].read
      contents ||= "\n" # SAFE bug
      @safe.nfs.create_file([raw[:path], raw[:name]].join('/'), contents, root_path: 'drive', is_private: raw[:root_type] == 'private')

      # Cache
      cached = case raw[:root_type]
      when 'public' then $cached_public
      when 'private' then $cached_private
      when 'outside' then $cached_alien
      else raise Errno::EBADF
      end

      # invalidates cache
      entries = cached.find_folder(raw[:path])
      entries[:valid] = false
      contents("/#{raw[:root_type]}#{raw[:path]}")
    end

    if raw[:tmp_hnd]
      raw[:tmp_hnd].close
    end
  end

  def size(path)
    file = get_file_entry(path)
    raise Errno::ENOENT if file.nil?

    return file['size']
  end
end

safe_vfs = SafeVFS.new
# safe_vfs.contents('/')
# FuseFS.start(safe_vfs, '/home/daniel/safe-disk')
FuseFS.main() { |opt| safe_vfs }
