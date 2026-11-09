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
	@echo "Clash Verge 已在会话里打开，回到浏览器窗口查看"
	@echo "改完订阅后执行 make restart 让代理生效"

clean:
	$(COMPOSE) down -v
