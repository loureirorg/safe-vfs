require 'rfusefs'
require 'safenet'
require 'tempfile'
require 'digest'
require 'date'

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
    @enable_cache   = true
    $cached_private = CacheTree.new
    $cached_public  = CacheTree.new

    @safe = SafeNet::Client.new({
      name: 'SAFE Virtual FS',
      version: '0.0.1',
      vendor: 'Daniel Loureiro',
      id: 'safe-vfs',
      permissions: ['SAFE_DRIVE_ACCESS']
    })
  end

  def contents(path)
    folders = path.split('/')
    folders.shift # 1st item is always blank
    if folders.empty? # path == '/'
      return ['public', 'private']
    end

    root_is_public = (folders.shift == 'public')
    path = '/' + folders.join('/') # relative to /public or /private

    # Safe DOESN'T have a /public and a /private folders,
    #  instead all private and public items are mixed together on root.
    #  For a /public  emulation, it checks on "/" for isPrivate=false items
    #  For a /private emulation, it checks on "/" for isPrivate=true  items
    safe_res = @safe.nfs.get_directory(path, root_path: 'drive')

    # invalidates cache
    cache = $cached_private.find_folder(path)
    cache[:folders] = {}
    cache[:files] = {}
    cache = $cached_public.find_folder(path)
    cache[:folders] = {}
    cache[:files] = {}

    # files
    safe_res['files'].each do |item|
      cache = item['isPrivate'] ? $cached_private : $cached_public
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

  def get_entries(path)
    folders = path.split('/')
    folders.shift # 1st item is always blank
    name = folders.pop
    return false if folders.empty? # /, /public, /private

    root_is_public = (folders.shift == 'public')
    path = '/' + folders.join('/') # relative to /public or /private

    # Cache
    entries = root_is_public ? $cached_public.find_folder(path) : $cached_private.find_folder(path)
    if ! entries[:valid]
      contents("/#{root_is_public ? 'public' : 'private'}/#{path}")
      entries = root_is_public ? $cached_public.find_folder(path) : $cached_private.find_folder(path)
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

  # def rename(from_path, to_path)
  #   puts "rename: #{from_path}, #{to_path}"
  #
  #   # remove "/private" or "/public": it doesn't matter
  #   folders = from_path.split('/')
  #   folders.shift # blank
  #   folders.shift # private or public
  #   from_path = ([''] + folders).join('/')
  #
  #   # remove "/private" or "/public": it doesn't matter
  #   folders = to_path.split('/')
  #   folders.shift # blank
  #   folders.shift # private or public
  #   name = folders.pop # file name
  #   to_path = ([''] + folders).join('/')
  #
  #   puts "#{from_path}, #{name}"
  #
  #   # puts @safe.nfs.move_file('drive', to_path, 'drive', from_path, 'copy')
  #   puts @safe.nfs.rename_file(from_path, name, root_path: 'drive')
  # end

  def touch(path, modtime)
    folders = path.split('/')
    folders.shift # remove blank
    root_is_public = (folders.shift == 'public')
    path = '/' + folders.join('/') # relative to /public or /private

    @safe.nfs.create_file(
      path,
      "\n", # SAFE bug!!!
      root_path: 'drive',
      is_private: root_is_public
    )
  end

  def file?(path)
    return ! get_file_entry(path).nil?
  end

  def times(path)
    file = get_file_entry(path)
    file = get_folder_entry(path) if ! file
    return [0, 0, 0] if ! file
    # raise Errno::ENOENT if ! file
    [
      DateTime.rfc3339(file['modifiedOn']).to_time.to_i,
      DateTime.rfc3339(file['modifiedOn']).to_time.to_i,
      DateTime.rfc3339(file['createdOn']).to_time.to_i
    ]
  end

  def directory?(path)
    folders = path.split('/')
    folders.shift # 1st item is always blank
    name = folders.pop
    return true if folders.empty? # /, /public, /private

    root_is_public = (folders.shift == 'public')
    path = '/' + folders.join('/') # relative to /public or /private

    # Cache
    entries = root_is_public ? $cached_public.find_folder(path) : $cached_private.find_folder(path)
    contents("/#{root_is_public ? 'public' : 'private'}/#{path}") if ! entries[:valid]
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

    root_is_public = (folders.shift == 'public')
    path = '/' + folders.join('/') # relative to /public or /private
    path = path + '/' if folders.any?

    path = path + name
    @safe.nfs.create_directory(path, root_path: 'drive', is_private: ! root_is_public)

    # invalidates cache
    entries = root_is_public ? $cached_public.find_folder(path) : $cached_private.find_folder(path)
    entries[:valid] = false

    true
  end

  def rmdir(path)
    raise Errno::EPERM if path == '/'

    folders = path.split('/')
    folders.shift # 1st item is always blank
    name = folders.pop

    root_is_public = (folders.shift == 'public')
    path = '/' + folders.join('/') # relative to /public or /private
    path = path + '/' if folders.any?

    path = path + name

    # CANNOT destroy if there are files inside
    entries = root_is_public ? $cached_public.find_folder(path) : $cached_private.find_folder(path)
    contents("/#{root_is_public ? 'public' : 'private'}/#{path}") if ! entries[:valid]
    raise Errno::ENOTEMPTY if entries[:files].any?

    @safe.nfs.delete_directory(path, root_path: 'drive', is_private: ! root_is_public)

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

    root_is_public = (folders.shift == 'public')
    path = '/' + folders.join('/') # relative to /public or /private

    # Write mode: SAFE lacks support for updating files
    #  Workaround: save contents in a local temp file and send it to the
    #  network in raw_close
    tmp_hnd = Tempfile.new('safe')
    tmp_hnd.binmode # binary mode

    {
      path: path,
      mode: mode,
      name: name,
      root_is_public: root_is_public,
      tmp_hnd: tmp_hnd,
      contents_changed: false,
      contents_loaded: false # for rw mode, we need to load the entire file if we want to change it
    }
  end

  def raw_read(path, offset, size, raw)
    # offset / length not implemented yet on SAFE
    if ! raw[:contents_loaded]
      file = @safe.nfs.get_file(
        [raw[:path], raw[:name]].join('/'),
        root_path: 'drive',
        is_private: raw[:root_is_public]
      )
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
        is_private: raw[:root_is_public]
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
      @safe.nfs.delete_file([raw[:path], raw[:name]].join('/'), root_path: 'drive', is_private: raw[:root_is_public])
      raw[:tmp_hnd].seek(0)
      contents = raw[:tmp_hnd].read
      contents ||= "\n" # SAFE bug
      @safe.nfs.create_file([raw[:path], raw[:name]].join('/'), contents, root_path: 'drive', is_private: raw[:root_is_public])

      # invalidates cache
      entries = raw[:root_is_public] ? $cached_public.find_folder(raw[:path]) : $cached_private.find_folder(raw[:path])
      entries[:valid] = false
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
# FuseFS.start(safe_vfs, '/mnt/test')
FuseFS.mount() { |opt| safe_vfs }
