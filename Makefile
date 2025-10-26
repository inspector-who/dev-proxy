.ONESHELL:
.PHONY: init init-network networks-prune networks-list

init:
	@bash -eu <<'SH'
	if [ -f .env ]; then
		echo ".env already exists; skip copying."
	else
		if [ -f .env.dist ]; then
			cp .env.dist .env
			echo "Created .env from .env.dist"
		else
			echo "Warning: .env.dist not found; nothing to copy" >&2
		fi
	fi
	SH

# Поднимает общую traefik-сеть и, при необходимости, локальный traefik
init-network:
	@bash -eu <<'SH'
	NETWORK_NAME="$${TRAEFIK_NETWORK:-traefik}"
	echo "Ensuring shared network '$${NETWORK_NAME}' exists..."
	if ! docker network inspect "$$NETWORK_NAME" >/dev/null 2>&1; then
		# Try to create with default settings first
		if docker network create -d bridge "$$NETWORK_NAME" >/dev/null 2>&1; then
			echo "Created network '$${NETWORK_NAME}'"
		else
			echo "Default network create failed. Will try explicit subnets (IPAM pool exhaustion workaround)..."
			# Try with a set of candidate subnets or user-provided value
			CANDIDATE_SUBNETS="$${TRAEFIK_SUBNETS:-$${TRAEFIK_SUBNET:-} 172.30.0.0/16 172.31.0.0/16 10.10.0.0/16 192.168.100.0/24}"
			CREATED=0
			for net in $$CANDIDATE_SUBNETS; do
				[ -z "$$net" ] && continue
				echo "Trying subnet $$net ..."
				if docker network create -d bridge --subnet "$$net" "$$NETWORK_NAME" >/dev/null 2>&1; then
					echo "Created network '$${NETWORK_NAME}' with subnet $$net"
					CREATED=1
					break
				fi
			done
			if [ "$$CREATED" -ne 1 ]; then
				echo "Failed to create network '$${NETWORK_NAME}'."
				echo "Hints:"
				echo " - Provide a free subnet via TRAEFIK_SUBNET=10.123.0.0/16 make init-network"
				echo " - Or run 'make networks-prune' to clean up unused docker networks and retry"
				exit 1
			fi
		fi
	else
		echo "Network '$${NETWORK_NAME}' already exists."
	fi
	# Если traefik уже крутится где-то (контейнер на образе traefik), пропускаем запуск локального
	if [ -z "$$(${SHELL:-bash} -lc 'docker ps -q -f ancestor=traefik')" ]; then
		echo "No running Traefik found. Starting local Traefik stack..."
		docker compose -p dev-proxy -f docker-compose.yml up -d
	else
		echo "Traefik seems to be running already. Skipping local Traefik start."
	fi
	SH

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
