.ONESHELL:
.PHONY: init init-network networks-prune networks-list

init:
	@bash scripts/init.sh

init-network:
	@bash scripts/init-network.sh

# Управление локальным traefik-стеком
traefik-up:
	docker compose up -d

traefik-down:
	docker compose down --remove-orphans

traefik-logs:
	docker compose logs -f --no-color

# Хелперы для сетей Docker
networks-prune:
	@read -p "This will remove ALL unused docker networks. Continue? [y/N] " ans; \
	if [ "$$ans" = "y" ] || [ "$$ans" = "Y" ]; then \
		echo "Pruning unused networks..."; \
		docker network prune -f; \
	else \
		echo "Cancelled."; \
	fi

networks-list:
	@echo "Existing docker networks (name | driver | subnet):"; \
	docker network ls --format '{{.Name}}\t{{.Driver}}' | while read -r name driver; do \
		subnet=$$(docker network inspect $$name -f '{{range .IPAM.Config}}{{.Subnet}}{{end}}' 2>/dev/null); \
		echo "$$name\t$$driver\t$$subnet"; \
	done
