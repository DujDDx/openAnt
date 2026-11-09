IMAGE    ?= claude-desktop-xpra:latest
COMPOSE  ?= docker compose

.PHONY: help build up down restart logs shell password clean clash

help:
	@echo "build     构建镜像"
	@echo "up        后台启动（会先构建）"
	@echo "down      停止并移除容器"
	@echo "restart   重启容器"
	@echo "logs      跟踪日志"
	@echo "shell     进入容器"
	@echo "password  查看当前访问密码"
	@echo "clash     在会话里打开 Clash Verge 窗口（改订阅用）"
	@echo "clean     停止并删除数据卷（会丢失登录态）"

build:
	docker build -t $(IMAGE) .

up:
	$(COMPOSE) up -d --build

down:
	$(COMPOSE) down

restart:
	$(COMPOSE) restart

logs:
	$(COMPOSE) logs -f

shell:
	$(COMPOSE) exec claude-desktop bash

password:
	$(COMPOSE) exec claude-desktop cat /home/claude/.config/claude-xpra/password

clash:
	$(COMPOSE) exec -d claude-desktop /usr/local/bin/clash-gui.sh
	@sleep 12
	@$(COMPOSE) exec -T claude-desktop bash -lc 'if pgrep -x verge-mihomo >/dev/null; then echo "Clash 窗口已打开，内核已在运行"; else echo "Clash 窗口已打开；如果它提示「需要更新系统服务」，在窗口里点「继续使用 SIDECAR」即可"; fi'

clean:
	$(COMPOSE) down -v
