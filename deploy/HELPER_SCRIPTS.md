# 一次性部署与诊断脚本

仓库根目录的 `_*.py` 是人工执行的辅助脚本，不参与应用运行。
SSH 脚本依赖 `paramiko`，Git 辅助脚本依赖 `dulwich`。

SSH 登录密码统一从环境变量 `TRACK_SSH_PASSWORD` 读取；运行前在当前终端设置。
服务器地址、用户名、目录和容器名仍使用脚本内的固定配置，执行前需核对目标环境。

| 脚本 | 用途及实际操作 |
| --- | --- |
| `_deploy_probe.py`、`_deploy_probe2.py`、`_deploy_probe3.py`、`_deploy_probe4.py` | 查询服务器、Docker、Nginx、磁盘和端口信息 |
| `_port_check.py` | 查询监听端口 |
| `_deploy_upload.py` | 生成部署压缩包、上传服务器并重建部署 |
| `_deploy_envs.py` | 部署测试和正式两套环境，停止旧单环境栈 |
| `_deploy_fix_pip.py` | 覆盖远端 Dockerfile 的 pip 镜像配置并重建服务 |
| `_deploy_retention.py` | 上传数据保留策略代码、重建两套服务，并执行测试环境清理 |
| `_fix_nginx_track.py` | 上传 Nginx 配置、重建 Web 容器并写入测试事件验证接口 |
| `_check_events.py` | 查询数据库、日志和接口，并写入测试事件 |
| `_verify_retention.py` | 检查保留策略配置，重建并启动服务 |
| `_verify_prod_ret.py` | 检查正式环境、重建服务，在测试和正式环境执行过期数据清理 |
| `_purge_once.py` | 在配置了服务端依赖和数据库连接的环境中执行一次过期数据删除 |
| `_git_commit_dulwich.py` | 绕过历史 Git mmap 故障，以固定提交信息和作者创建提交 |
| `_git_fix_screenshots.py` | 按固定路径清单重建最近一次提交，直接改写 `main` 分支指向 |

这些脚本保留了当时部署的固定参数，不应作为通用部署入口直接批量运行。
`_track_bundle.tgz` 是 `_deploy_upload.py` 生成的部署产物，不提交到 Git。
