#!/bin/sh
# Apple container 部署脚本（无 compose 的两容器编排）
# 前提：macOS 26 + Apple Silicon，已安装 apple/container
set -e
container system start
container build -t coolqbot-rs -f deploy/Containerfile .
# 协议实现端（NapCat）——镜像名以你实际使用的为准
container run -d --name napcat -v "$HOME/botdata/napcat:/app/napcat/config" mlikiowa/napcat-docker
# bot 本体
container run -d --name coolqbot -v "$HOME/botdata/bot:/data" coolqbot-rs
# 注意：Apple container 是 VM-per-container，容器互访地址用
# `container inspect napcat` 查到的 IP，写进 bot 的 config.toml
