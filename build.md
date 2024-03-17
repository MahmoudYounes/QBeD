# overview
Describes the distribution build process

# steps
- the new distribution requires a new partition. you can use fdisk to do that. I would recommend gparted with a UI
  in order not to get confused and delete the root FS by mistake 🤷
- TODO: script partition cresation using sfdisk
- export env var LFS=/mnt/qbed
- mkdir -v $LFS/sources
- download the packages. use the wget-list-systemd file in this repo. (Note: apparently there should be a wget-list
  file based on the init system provided with the book?)

