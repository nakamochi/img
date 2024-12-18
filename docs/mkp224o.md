# mkp224o installation instructions

[mkp224o](https://github.com/cathugger/mkp224o) is a tool to generate onion service keys.

## Ubuntu Linux

```
$ sudo apt install gcc libc6-dev libsodium-dev make autoconf
$ git clone https://github.com/cathugger/mkp224o
$ cd mkp224o
$ ./autogen.sh
$ ./configure
$ make
$ sudo cp mkp224o /usr/local/bin/
```
