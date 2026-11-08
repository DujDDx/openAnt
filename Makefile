IMAGE    ?= claude-desktop-xpra:latest
COMPOSE  ?= docker compose

.PHONY: help build up down restart logs shell password clean

help:
	@echo "build     构建镜像"
	@echo "up        后台启动（会先构建）"
	@echo "down      停止并移除容器"
	@echo "restart   重启容器"
	@echo "logs      跟踪日志"
	@echo "shell     进入容器"
	@echo "password  查看当前访问密码"
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

clean:
	$(COMPOSE) down -v
