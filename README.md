A portable mountable drive for the SAFE network.

## Download / Install
```bash
> wget "https://github.com/loureirorg/safe-vfs/raw/master/mount.safevfs"
> chmod +x mount.safevfs
```

## Usage
```bash
> ./mount.safevfs /mnt/test
```

Where */mnt/test* is your mount point.
The mount point **MUST** be an absolute path (i.e. DO NOT use a relative path like `./mount.safevfs ./my-folder`).
