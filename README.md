Personal fork of [Conty](https://github.com/Kron4ek/Conty) with following changes

- Made bootstrap creation script run using user namespace allowing building
  image without root permissions on systems that support user namespaces.
- Switched from using bundled utilities to using utilities available in arch.
- Rewrote conty-start.sh as posix shell script that can be run using busybox
  removing the need for host system to have coreutils to run conty.
- Made it possible to disable Chaotic-AUR repository and disabled it by default.
- Cleaned up default package list keeping only packages that I need.
- Removed nvidia driver handling & gui as I dont use them.
- Removed ability to mount image as overlayfs. Just rebuild conty when changes
  need to be done to it.
- Removed support for isolating X11 using Xephyr. Instead now only current Xorg
  display is being passed when sandbox is enabled making it possible to simply
  run conty via gamescope if needed which will achieve same result as Xephyr
  isolation available previously.
- Reworked conty sandbox to produce stricter sandbox by default & switch from.
  using arbitrary sandbox levels to explicit parameters that tell what should be
  exposed on the system.
- Made most options that were configured via environment variables be
  configurable via command line flags.
- Added option to build new conty image using conty itself by bundling all
  install scripts in it.

# Conty
Compressed unprivileged Linux container based on Arch linux packed into a single
executable that works on most Linux distros.

## Usage
Build executable by running `create-conty.sh` - unprivileged namespace support
or superuser privileges are required to run. This will produce `conty.sh` in
`build` directory by default which can be run as-is.

```
$ ./conty.sh -h
Usage: conty.sh [OPTION]... COMMAND

Sandboxing:
  -n    Disable network access.
  -s    Enable a sandbox which, by default does following things:
        - Hides user & system files by mounting everything as tmpfs.
        - Mounts X11 socket pointed to by $DISPLAY environment variable and
          Xauthority file pointed by $XAUTHORITY environment variable if they
          are set.
        - Mounts wayland socket pointed to by $WAYLAND_DISPLAY environment
          variable if it is set.
        - Clears environment variables.
        You can make sandbox less or more strict by using some arguments below
        or by passing any arguents supported by bubblewrap.
  -d    Allow dbus access when sandbox is enabled.
  -e    Do not clear environment variables when sandbox is enabled.
  -p    Persist home directory when sandbox is enabled.
        By default home is persisted at /home/ivan/.local/share/conty/home.
        You can customize it by setting $HOME_DIR environment variable.

Rebuild:
  -u    Rebuild conty container and exit.
        This will copy files used to build conty that are included in the image
        into build directory and produce new conty executable using them. Build
        settings, if needed can be customized by creating
        ~/.config/conty/settings.sh file which will replace setings file from
        the image.
        Rebuild command uses host system utilities to work and will error out
        if some of them are not available with list of required dependencies.
  -c    Remove rebuild directory if rebuild was finished successfully

Miscellaneous:
  -m    Mount/unmount the image
        The image will be mounted if it's not, unmounted otherwise.
  -h    Display this help message and exit.
  -H    Display bubblewrap help and exit.
  -V    Display version of the image and exit.
  --    Treat the rest of arguments as COMMAND.

COMMAND is passed directly to bubblewrap, so all bubblewrap arguments are
supported.

Environment variables:
  DISABLE_NET       Same as providing -n flag.
  SANDBOX           Same as providing -s flag.
  ENABLE_DBUS       Same as providing -d flag.
  KEEP_ENV          Same as providing -e flag.
  PERSIST_HOME      Same as providing -p flag.
  REBUILD_CLEAR     Same as providing -c flag.
  HOME_DIR          Sets the directory where home directory will be persisted
                    when sandbox is enabled and -p flag is provided.
  BUILD_DIR         Sets the directory where conty rebuild will be done.
                    Can be either relative or full path.
                    Note that currently setting this path to tmpfs will break
                    rebuild if there are any AUR packages set to be installed
                    in settings.
  USE_SYS_UTILS     Tells the script to use squashfuse/dwarfs and bwrap
                    installed on the system instead of the builtin ones.
  CUSTOM_MNT        Sets a custom mount point for the Conty. This allows
                    Conty to be used with already mounted filesystems.
                    Conty will not mount its image on this mount point,
                    but it will use files that are already present
                    there.

If the executed script is a symlink with a different name, said name
will be used as the command name.
For instance, if the script is a symlink with the name \"wine\" it will
automatically run wine during launch.
```

### How to update
Either built new one using `create-conty.sh` or run `conty.sh -u` which will
rebuild itself using `create-conty.sh` that was included inside image as part of
image creation process.

## Known issues

* Some Windows applications running under Wine complain about lack of free disk space. This is because under Conty root partition is seen as full and read-only, so some applications think that there is no free space, even though you might have plenty of space in your HOME. The solution is simple, just run `winecfg`,  move to "Drives" tab and add your `/home` as an additional drive (for example, `D:`), and then install applications to that drive. More info [here](https://github.com/Kron4ek/Conty/issues/67#issuecomment-1460257910).
* AppImages do not work under Conty. This is because bubblewrap, which is used in Conty, does not allow SUID bit (for security reasons), which is needed to mount AppImages. The solution is to extract an AppImage application before running it with Conty. Some AppImages support `--appimage-extract-and-run` argument, which you can also use.
* Application may show errors (warnings) about locale, like "Unsupported locale setting" or "Locale not supported by C library". This happens because Conty has a limited set of generated locales inside it, and if your host system uses locale that is not available in Conty, applications may show such warnings. This is usually not a critical problem, most applications will continue to work without issues despite showing the errors. But if you want, you can create a Conty executable and include any locales you need.
* Conty may have problems interfacing with custom url protocols (such as `steam://` and `sgdb://`), apps that uses Native Host Messengers (such as browser extensions for Plasma Host Integration / KDE Connect, KeePassXC, and download managers), and login token exchange (such as trying to log-in a natively-installed GitHub Desktop app with a browser inside Conty) if there is packages that handle such protocols installed (for example, `plasma-browser-integration` for KDE Plasma extension inside browser).
* Steam can't make screenshots when running directly under gamescope. The solution is to first run gamescope separately and then attach Steam client to it, like this:
    ```
    termA $ ./conty.sh gamescope -w 1920 -h 1080
    termB $ DISPLAY=:1 ./conty.sh steam
    ```
    `DISPLAY=:1` can have another number - get it from the `gamescope` output:

    > wlserver: [xwayland/server.c:108] Starting Xwayland on :1

    Solution from https://www.reddit.com/r/linux_gaming/comments/1ds1ei3/steam_input_not_working_under_gamescope/lb10mmf/

* The game is not starting or starting only when you disable your additional displays (for example Armies of Exigo): use Gamescope - see previous point.

## Credits
Based on [Conty](https://github.com/Kron4ek/Conty)
