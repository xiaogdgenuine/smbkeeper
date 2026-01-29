# Building a passthrough file system

Expose an existing path as its own file system by using the FSKit framework.

## Overview

The `PassthroughFS` example reads from an existing path on your current file system and exposes the path's contents as a new file system.
After running and installing the sample, you can use a Terminal command like `mount -t passthrough ~/Documents ~/passthrough-fs` to present the contents of your Documents directory as another file system, mounted at `passthrough-fs`.
The `-t passthrough` flag tells `mount` that the type of the file system is `passthrough`, which sends its requests to the sample's extension.

For more information, see the full article, [Building a passthrough file system](https://developer.apple.com/documentation/fskit/building-a-passthrough-file-system).
