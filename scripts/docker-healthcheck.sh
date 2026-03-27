#!/bin/bash
if [[ -z $VIRTUAL_ENV ]]; then
    source ${AIRFLOW_INSTALL_DIR}/venv/bin/activate 
fi

case "$1" in
  webserver)
    # 1- checar se a env AIRFLOW__WEBSERVER__BASE_URL existe
    # 2- Sed no airflow.cfg para pegar o valor da env acima
    SCRIPT_NAME=$(echo "/${AIRFLOW__WEBSERVER__BASE_URL##*/*/*/}")
    curl --fail http://localhost:8080${SCRIPT_NAME}/health
    ;;    

  scheduler)
    # "curl", "--fail", "http://localhost:8974/health"] if AIRFLOW__SCHEDULER__ENABLE_HEALTH_CHECK: 'true'
    airflow jobs check --job-type SchedulerJob --hostname "${HOSTNAME}"
    ;;

  worker)
    celery --app airflow.providers.celery.executors.celery_executor.app inspect ping -d "celery@$${HOSTNAME}" || \
    celery --app airflow.executors.celery_executor.app inspect ping -d "celery@${HOSTNAME}"
    ;;

  triggerer)
    airflow jobs check --job-type TriggererJob --hostname "${HOSTNAME}"
    ;;
  
  flower)
    curl --fail http://localhost:5555/flower/
    ;;

  *)
    exit 1
    ;;
esac
