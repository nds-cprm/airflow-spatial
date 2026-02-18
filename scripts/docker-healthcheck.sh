#!/bin/bash
if [[ -z $VIRTUAL_ENV ]]; then
    source ${AIRFLOW_INSTALL_DIR}/venv/bin/activate 
fi

case "$1" in
  webserver)
    curl --fail http://localhost:8080${SCRIPT_NAME}/health
    ;;    

  scheduler)
    airflow jobs check --job-type SchedulerJob --hostname "${HOSTNAME}"
    ;;

  worker)
    celery --app airflow.executors.celery_executor.app inspect ping -d "celery@${HOSTNAME}"
    ;;

  triggerer)
    airflow jobs check --job-type TriggererJob --hostname "${HOSTNAME}"
    ;;
  
  flower)
    curl --fail http://localhost:5555/flower
    ;;

  *)
    exit 1
    ;;
esac
