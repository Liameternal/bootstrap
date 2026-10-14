# Bootstrap

这个项目用于初始化一台 Linux 机器：安装基础工具、同步个人 dotfiles，并按配置选择是否安装 Miniconda、Docker、kubectl、kind、Open vSwitch 等高级组件。

脚本按幂等方式设计，重复执行时会尽量复用已有安装结果，例如已存在的仓库会更新，已存在的插件目录会跳过。

## 文件说明

- `bootstrap-linux.sh`：主脚本，负责检测系统、安装工具、同步配置并执行初始化流程。
- `bootstrap.conf`：默认配置文件，控制安装层级、dotfiles 仓库地址和高级组件开关。
- `.gitignore`：Git 忽略规则，目前忽略 `.agents/`。

## 快速开始

```bash
./bootstrap-linux.sh
./bootstrap-linux.sh --dry-run
./bootstrap-linux.sh --config ./bootstrap.conf -v
```

常用参数：

- `--config PATH`：指定配置文件，默认读取脚本同目录的 `bootstrap.conf`。
- `--dry-run`：只打印将要执行的动作，不实际修改系统。
- `--log-file PATH`：指定日志文件路径。
- `-v, --verbose`：启用详细日志。
- `-h, --help`：显示帮助信息。

## 配置说明

`bootstrap.conf` 会被脚本以 shell source 的方式读取，请保持 `变量名=值` 格式，不要在等号两侧加空格。

- `PROFILE`：安装层级。
  - `minimal`：只执行基础安装。
  - `advanced`：先执行 `minimal`，再根据高级组件开关安装额外工具。
- `REPO_URL`：远程 dotfiles 仓库地址，默认是 `https://github.com/Liameternal/myconfig.git`。
- `DEST_DIR`：远程 dotfiles 仓库在本机的目标目录，默认是 `$TARGET_HOME/myconfig`。
- `INSTALL_CONDA`：是否安装 Miniconda。
- `INSTALL_DOCKER`：是否安装 Docker。
- `INSTALL_KUBECTL`：是否安装 kubectl。
- `INSTALL_KIND`：是否安装 kind。
- `INSTALL_OVS`：是否安装 Open vSwitch。
- `MINICONDA_URL`：Miniconda 安装脚本地址，通常不需要修改。

当前默认配置为 `PROFILE=advanced`，并启用全部高级组件开关。

## 安装内容

`minimal` 会执行：

- 检测发行版和包管理器。
- 安装基础工具，例如 `git`、`curl`、`wget`、`zsh`、`tmux`、`vim`、`fzf`、`ripgrep`。
- 安装 oh-my-zsh 和常用插件。
- 通过系统包管理器安装可选的 Pygments 插件依赖，不安装 pip，也不使用 pip 兜底。
- 同步 `myconfig` 仓库。
- 复制 `.zshrc`、`.vimrc`、`.tmux.conf`，并同步 Vim `ftdetect` 目录。
- 安装 Vundle 和 tmux plugin manager。

`advanced` 会在 `minimal` 之后先安装开发和排障工具，再按配置安装高级组件：

- 开发和排障工具：例如 `p7zip`、`procps-ng`、`sysstat`、`iproute`、`perf`、`tcpdump`、`strace`、`bpftrace`、`gdb`、`shellcheck`、`iscsi-initiator-utils`、`unrar`、`net-snmp-utils`、`helm`、`sshpass`、`golang`。这些名称经过 `pkg_name()` 映射后安装，不受 `INSTALL_*` 开关控制。
- Miniconda
- Docker
- kubectl
- kind
- Open vSwitch

## 包名映射与组件依赖

包名差异集中由 `pkg_name()` 处理。Arch/CachyOS 使用以下映射：

| 安装列表名称 | pacman 包名 |
| --- | --- |
| `python3-pygments` | `python-pygments` |
| `net-snmp-utils` | `net-snmp` |
| `iscsi-initiator-utils` | `open-iscsi` |
| `golang` | `go` |
| `iproute` | `iproute2` |
| `p7zip` | `7zip` |

Pygments 在 apt、dnf、yum、zypper 下使用 `python3-pygments`；安装失败会记录日志并继续。其 Python 依赖由系统包管理器解析，脚本本身不调用 pip。

Arch/CachyOS 的 Open vSwitch 使用 `ovs-vswitchd.service`，该单元会启动 `ovsdb-server.service`；其他已支持路径使用 `openvswitch.service`。OVS 包安装失败时跳过服务启动。

kind 优先使用 Go 安装，没有 Go 时通过 curl 下载二进制。创建集群还需要容器运行时；关闭 `INSTALL_DOCKER` 时需自行准备可用运行时。kubectl 的二进制下载依赖 curl。Miniconda、kubectl 和 kind 的下载地址目前默认面向 Linux x86_64，其他架构需要另行适配。

## 使用注意

- 不要使用 `sudo ./bootstrap-linux.sh` 或 `sudo bash bootstrap-linux.sh` 直接调用脚本。普通用户直接运行即可，脚本会在需要系统权限时自动使用 `sudo`。
- root 用户可以在 root 登录 shell 中直接运行脚本，配置会安装到 `/root`；例如先执行 `sudo -i` 或 `su -`，再进入项目目录运行 `bash bootstrap-linux.sh`。
- 日志默认写到脚本所在目录的 `bootstrap-linux.log`，也可以用 `--log-file` 覆盖。
- 脚本默认读取同目录的 `bootstrap.conf`；如果默认配置文件不存在，会按 `PROFILE=minimal` 的内置默认值运行。
- `PROFILE=advanced` 且某个 `INSTALL_*` 没有写在配置文件中时，该组件默认启用。
- Arch/CachyOS 在安装前执行一次 `pacman -Syu --noconfirm` 升级阶段；成功后，所有软件包安装使用 `pacman -S --needed --noconfirm`，不再重复同步仓库数据库。升级失败时中止后续安装，`--dry-run` 只打印命令。

包名和服务依据：[Arch 包仓库](https://archlinux.org/packages/)、[Open vSwitch](https://wiki.archlinux.org/title/Open_vSwitch)。跨发行版安装仍取决于目标系统版本和已启用的仓库，可选工具缺包时会记录日志并继续。

## 后续手动步骤

脚本执行完成后，可能还需要手动完成以下操作：

```bash
# 安装 tmux 插件
~/.tmux/plugins/tpm/bin/install_plugins

# 如果 headless 环境中 Vim 插件安装失败，手动执行
vim +PluginInstall +qall
```

首次执行完成后建议重启一次，使默认 shell 变更和 Docker group membership 生效。
