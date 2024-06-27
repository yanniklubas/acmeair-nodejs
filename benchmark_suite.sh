#!/usr/bin/env bash
set -eou pipefail

SERVER_IP="localhost"
BENCHMARKS=(
	"linear.csv"
)
DURATION_SEC=600
VIRTUAL_USERS=500
THREADS=256
TIMEOUT_MS=3000
WARMUP_DURATION_SEC=120
WARMUP_RPS=25
WARMUP_PAUSE_SEC=10
LOAD_GENERATOR_LOC="$HOME/load_generator"
JAR_NAME="httploadgenerator.jar"
PORT=9080

remote_docker() {
	local cmd="$1"
	local docker_cmd
	case "$cmd" in
	"up")
		docker_cmd="docker compose up --build --detach --force-recreate --wait --quiet-pull"
		;;
	"down")
		docker_cmd="docker compose down -v"
		;;
	*)
		printf "invalid argument: cmd must be {up | down }, not %s\n" "$cmd" >&2
		;;
	esac
	ssh "$USER@$SERVER_IP" '
cd $HOME/acmeair-nodejs
'"$docker_cmd"' 2>/dev/null >&2'
}

(
	SCRIPT_PATH=$(dirname -- "${BASH_SOURCE[0]}")
	SCRIPT_PATH=$(readlink -f -- "${SCRIPT_PATH}")
	cd "${SCRIPT_PATH}"
	# Copy load generator .jar, if not exists
	JAR_NAME="httploadgenerator.jar"
	if [ ! -f "$PWD/document/workload/http-loadgenerator/$JAR_NAME" ]; then
		if [ ! -f "$LOAD_GENERATOR_LOC/$JAR_NAME" ]; then
			printf "expected load generator jar at %s\n" "$LOAD_GENERATOR_LOC/$JAR_NAME" >&2
			exit 1
		fi
		cp "$LOAD_GENERATOR_LOC/$JAR_NAME" "$PWD/document/workload/http-loadgenerator/$JAR_NAME"
	fi

	START_TIME=$(date +%s)
	MEASUREMENTS_DIR="$HOME/measurements"
	mkdir -p "$MEASUREMENTS_DIR"
	VOLUME_NAME="prometheus-data-$START_TIME"

	ssh "$USER"@"$SERVER_IP" '
docker volume create '"$VOLUME_NAME"' >/dev/null
cd $HOME/acmeair-nodejs
echo MG_PROMETHEUS_VOLUME_NAME='"$VOLUME_NAME"' > .env
'

	for t in "${BENCHMARKS[@]}"; do
		oIFS="$IFS"
		IFS=' '
		read -ra RUN <<<"$t"
		IFS="$oIFS"
		unset oIFS
		DIR_NAME="acme-air"
		RUN_DIR="$MEASUREMENTS_DIR/$DIR_NAME"

		PROFILE="$PWD/document/workload/http-loadgenerator/${RUN[0]}"
		WORKLOAD_FILE="$PWD/document/workload/http-loadgenerator/workload.yml"
		if [ -d "$RUN_DIR" ]; then
			TS=$(date +%s)
			BACKUP="$RUN_DIR-bck-$TS"
			printf "directory %s already exists! Backing up to %s!\n" "$RUN_DIR" "$BACKUP"
			mv "$RUN_DIR" "$BACKUP"
		fi
		mkdir -p "$RUN_DIR"

		CONFIG_FILE="$RUN_DIR/config.yml"
		printf "Saving benchmark configuration to %s\n" "$CONFIG_FILE" >&2
		touch "$CONFIG_FILE"
		printf "profile: %s\n" "$PROFILE" >"$CONFIG_FILE"
		{
			printf "server_ip: %s\n" "$SERVER_IP"
			printf "duration: %d\n" "$DURATION_SEC"
			printf "threads: %d\n" "$THREADS"
			printf "virtual_users: %d\n" "$VIRTUAL_USERS"
			printf "timeout: %d\n" "$TIMEOUT_MS"
			printf "warmup_duration: %d\n" "$WARMUP_DURATION_SEC"
			printf "warmup_rps: %d\n" "$WARMUP_RPS"
			printf "warmup_pause: %d\n" "$WARMUP_PAUSE_SEC"
			printf "workload: %s\n" "$WORKLOAD_FILE"
		} >>"$CONFIG_FILE"

		printf "Starting ACME AIR server on %s\n" "$SERVER_IP"
		remote_docker "up"

		curl "http://$SERVER_IP:$PORT/rest/api/loader/load"

		YAML_FILE="$(mktemp)"
		sed -e 's/{{ACMEAIR_WEB_HOST}}/'"host.docker.internal:$PORT"'/g' "$WORKLOAD_FILE" >"$YAML_FILE"
		cd "$PWD/document/workload/http-loadgenerator"
		YAML_PATH="$YAML_FILE" \
			BENCHMARK_RUN="$RUN_DIR" \
			PROFILE="$PROFILE" \
			BENCHMARK_DURATION="$DURATION_SEC" \
			DIRECTOR_THREADS="$THREADS" \
			VIRTUAL_USERS="$VIRTUAL_USERS" \
			TIMEOUT="$TIMEOUT_MS" \
			WARMUP_DURATION="$WARMUP_DURATION_SEC" \
			WARMUP_RPS="$WARMUP_RPS" \
			WARMUP_PAUSE="$WARMUP_PAUSE_SEC" \
			docker compose up \
			--build --abort-on-container-exit --force-recreate

		remote_docker "down"
		rm "$YAML_FILE"
	done

	ssh "$USER"@"$SERVER_IP" 'rm /tmp/metrics.tar.gz 2>/dev/null
docker run \
--rm \
--volume /tmp:/backup \
--volume '"$VOLUME_NAME"':/data \
--user 65534:65534 \
busybox \
tar -czf /backup/metrics.tar.gz /data/
rm $HOME/acmeair-nodejs/.env
docker volume rm '"$VOLUME_NAME"''
	scp "$USER"@"$SERVER_IP":/tmp/metrics.tar.gz "$MEASUREMENTS_DIR/metrics.tar.gz"
)
