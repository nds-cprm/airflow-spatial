#!/bin/bash
# Docker expects 0 (healthy) or 1 (unhealthy): every check ends with "|| exit 1"
if [[ -z $VIRTUAL_ENV ]]; then
    source ${AIRFLOW_INSTALL_DIR}/venv/bin/activate
fi

# Webserver /health URL, honoring the path of AIRFLOW__WEBSERVER__BASE_URL (e.g. http://host/airflow)
webserver_health_url() {
    local BASE_PATH=""

    if [[ -n "$AIRFLOW__WEBSERVER__BASE_URL" ]]; then
        BASE_PATH="${AIRFLOW__WEBSERVER__BASE_URL#*://}"
        if [[ "$BASE_PATH" == */* ]]; then
            BASE_PATH="/${BASE_PATH#*/}"
            BASE_PATH="${BASE_PATH%/}"
        else
            BASE_PATH=""
        fi
    fi

    echo "http://localhost:${AIRFLOW__WEBSERVER__WEB_SERVER_PORT:-8080}${BASE_PATH}/health"
}

case "$1" in
  webserver)
    curl --fail --silent --show-error --max-time 10 "$(webserver_health_url)" > /dev/null || exit 1
    ;;

  scheduler)
    # --local matches the hostname the same way Airflow records it on the job
    airflow jobs check --job-type SchedulerJob --local || exit 1
    ;;

  worker)
    celery --app airflow.providers.celery.executors.celery_executor.app inspect ping -d "celery@${HOSTNAME}" || exit 1
    ;;

  triggerer)
    airflow jobs check --job-type TriggererJob --local || exit 1
    ;;

  standalone)
    # Webserver /health reports metadatabase, scheduler and triggerer; all reported statuses must be "healthy"
    python -c 'import json, sys, urllib.request; health = json.load(urllib.request.urlopen(sys.argv[1], timeout=10)); print(health); sys.exit(0 if all(c["status"] == "healthy" for c in health.values() if isinstance(c, dict) and c.get("status") is not None) else 1)' \
        "$(webserver_health_url)" || exit 1
    ;;

  flower)
    curl --fail --silent --show-error --max-time 10 http://localhost:5555/flower/ > /dev/null || exit 1
    ;;

  *)
    exit 1
    ;;
esac
