CLUSTER_PATH = spec/cluster/

.PHONY: cluster_config
cluster_config:
	rm -rf ${CLUSTER_PATH}clickhouse01 ${CLUSTER_PATH}clickhouse02 ${CLUSTER_PATH}clickhouse03 ${CLUSTER_PATH}clickhouse04
	mkdir -p ${CLUSTER_PATH}clickhouse01 ${CLUSTER_PATH}clickhouse02 ${CLUSTER_PATH}clickhouse03 ${CLUSTER_PATH}clickhouse04
	REPLICA=01 SHARD=01 envsubst < ${CLUSTER_PATH}config.xml > ${CLUSTER_PATH}clickhouse01/config.xml
	REPLICA=02 SHARD=01 envsubst < ${CLUSTER_PATH}config.xml > ${CLUSTER_PATH}clickhouse02/config.xml
	REPLICA=03 SHARD=02 envsubst < ${CLUSTER_PATH}config.xml > ${CLUSTER_PATH}clickhouse03/config.xml
	REPLICA=04 SHARD=02 envsubst < ${CLUSTER_PATH}config.xml > ${CLUSTER_PATH}clickhouse04/config.xml
	cp ${CLUSTER_PATH}users.xml ${CLUSTER_PATH}clickhouse01/users.xml
	cp ${CLUSTER_PATH}users.xml ${CLUSTER_PATH}clickhouse02/users.xml
	cp ${CLUSTER_PATH}users.xml ${CLUSTER_PATH}clickhouse03/users.xml
	cp ${CLUSTER_PATH}users.xml ${CLUSTER_PATH}clickhouse04/users.xml

.PHONY: cluster_up
cluster_up: cluster_config
	docker-compose -f ${CLUSTER_PATH}docker-compose.yml up

.PHONY: cluster_start
cluster_start:
	docker-compose -f ${CLUSTER_PATH}docker-compose.yml start

.PHONY: cluster_down
cluster_down:
	docker-compose -f ${CLUSTER_PATH}docker-compose.yml down

