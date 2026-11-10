IMAGE    ?= claude-desktop-xpra:latest
REPO     ?= claude-desktop-xpra
COMPOSE  ?= docker compose

.PHONY: help build up down restart logs shell password clash save verify-clean clean

help:
	@echo "build     构建镜像"
	@echo "up        后台启动（会先构建）"
	@echo "down      停止并移除容器"
	@echo "restart   重启容器"
	@echo "logs      跟踪日志"
	@echo "shell     进入容器"
	@echo "password  查看当前访问密码"
	@echo "clash     在会话里打开 Clash Verge 窗口（改订阅用）"
	@echo "save      把当前镜像导出到 dist/，用于离线分发"
	@echo "verify-clean  检查镜像里有没有登录态或订阅残留（分发前跑）"
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

# 导出成可迁移的 tar.gz；同时带上 latest 和 working 两个 tag
save:
	@mkdir -p dist
	docker tag $(IMAGE) $(REPO):working
	docker save $(IMAGE) $(REPO):working | gzip -1 > dist/$(REPO)-$(shell date +%Y-%m-%d).tar.gz
	@ls -lh dist/$(REPO)-*.tar.gz | tail -1

# 分发前检查：/home/claude 下不应有任何用户数据，也不应有订阅配置残留
verify-clean:
	@docker run --rm --entrypoint bash $(IMAGE) -c '\
		set -e; \
		n=$$(find /home/claude/.config/Claude /home/claude/.local/share /home/claude/.cache -type f 2>/dev/null | wc -l); \
		if [ "$$n" != "0" ]; then echo "发现 $$n 个用户数据文件，不能分发"; exit 1; fi; \
		hits=$$(grep -rIl -e "ai00.de" -e "388898.xyz" -e "sufe.us" -e "\.ai00\." /etc /home /opt /var 2>/dev/null | wc -l); \
		if [ "$$hits" != "0" ]; then echo "发现订阅配置残留"; exit 1; fi; \
		echo "镜像干净：无登录态、无订阅配置"'
