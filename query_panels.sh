#!/bin/bash

####Config####
INFLUXDB_HOST="localhost:8086"
     USERNAME="user"
     PASSWORD="password"
     DATABASE="homeassistant"

     DATA_DIR="/config/power"
     ENTITIES="${DATA_DIR}/entities.txt"
    GRAPH_OUT="${DATA_DIR}/graph.json"
   PANELS_OUT="${DATA_DIR}/panels.json"
  PANEL_COUNT=30  #ignored for discovered
####Config end###

usage () {
  echo "First time setup run:  $0 --discover"
  echo ""
  echo "Usage: $0 -d YYYY-MM-DD -h HH -e ENTITY -p POLL"
  echo
  echo "Options:"
  echo "  -d DATE    YYYY-MM-DD        (required)"
  echo "  -h HOUR    HH                (required)"
  echo "  -e ENTITY  power_3           (optional, echo only)"
  echo "  -p POLL    max|mean|first    (optional)"
  echo "  -m MODE    power|energy|live (optional)"
  echo ""
  echo "Example:"
  echo "  $0 -d 2025-07-31 -h 14 -e power_3 -m max -m power"
  echo "  home assistant will use date, hour, mode"
  echo ""
  exit 1
}


queryflux () {
  curl -sG http://${INFLUXDB_HOST}/query \
    --data-urlencode "db=${DATABASE}" \
    --data-urlencode "u=${USERNAME}" \
    --data-urlencode "p=${PASSWORD}" \
    --data-urlencode "q=${QUERY}"
}


discover() {
  echo "Discovering lifetime_power and matching power sensors..."

  QUERY='SHOW TAG VALUES FROM "kWh" WITH KEY = "entity_id"'
  readarray -t lifetime_entities < <(queryflux | jq -r '.results[0].series[0].values[][1]' | grep 'lifetime_power')

  > "${DATA_DIR}/entities.txt"
  for lifetime_entity in "${lifetime_entities[@]}"; do
    power_entity="${lifetime_entity/_lifetime/}"
    power_entity="${power_entity/lifetime_/}"

    QUERY="SELECT * FROM \"kW\" WHERE \"entity_id\" = '$power_entity' LIMIT 1"
    result=$(queryflux)

    if echo "$result" | jq -e '.results[0].series[0].values and (.results[0].series[0].values | length > 0)' > /dev/null 2>&1; then
      echo "Found data for $power_entity matched from $lifetime_entity"
      echo "- $power_entity" >> "${DATA_DIR}/entities.txt"
    else
      echo "No data for $power_entity (from $lifetime_entity)"
    fi
  done
}


writegraph () {
  local entity
  if [[ -s "$ENTITIES" ]]; then
    local power=$(sed 's/^- //' "$ENTITIES" | grep -E '^power$|_power$' | head -n 1)
    if [[ -n "$power" ]]; then
      #echo "Using $ENTITIES"
      entity="$power"
    else
      entity="power"
    fi
  fi
  if [[ "$MODE" == "ENERGY" || "$MODE" == "LIVE" ]]; then
    entity="${entity/power/lifetime_power}"
  fi

  QUERY="SELECT FIRST(value) FROM autogen.${UNITS} WHERE entity_id = '${entity}' AND time >= '${D_START}' AND time <= '${D_END}' GROUP BY time(1h) fill(0)"
  local values
  values=$(queryflux | jq '[.results[0].series[0].values[][1]]')

  if [[ $MODE == "ENERGY" || $MODE == "LIVE" ]]; then
    start_value=$(echo "$values" | jq '[.[] | select(. != null and . != 0)] | .[0]')    #incremental values. get the hourly difference, use previous values when zero or missing
    values=$(echo "$values" | jq --argjson start "$start_value" '
      reduce .[] as $end ([];
        . + [ if ($end == 0 or $end == null) then
                (.[-1] // 0)
              else
                ($end - $start) | if . < 0 then (.[-1] // 0) else . end
              end
            ] )')
  fi
  jq -n --argjson values "$values" '{ values: $values }' > "$GRAPH_OUT"
}

writepanels () {
  local entities=()
  if [[ -s "$ENTITIES" ]]; then
    mapfile -t entities < <(sed 's/^- //' "$ENTITIES")
    if [[ "$MODE" == "ENERGY" || "$MODE" == "LIVE" ]]; then
      #echo "Using $ENTITIES for panels"
      for i in "${!entities[@]}"; do
        if [[ "${entities[i]}" == *power* ]]; then
          entities[i]="${entities[i]/power/lifetime_power}"
        fi
      done
    fi
  else
    # the old way
    local count=$((PANEL_COUNT + 2))
    entities+=("${EN}power")
    for (( i=3; i<=count; i++ )); do
      entities+=("${EN}power_$i")
    done
  fi
  local or_entities=""
  for entity in "${entities[@]}"; do
    [[ -n "$or_entities" ]] && or_entities+=" OR "
    or_entities+="entity_id = '$entity'"
  done
  if [[ "$MODE" == "ENERGY" ]]; then    #energy
    QUERY="SELECT MAX(value) - MIN(value) as produced FROM autogen.${UNITS} WHERE (${or_entities}) AND time >= '${D_START}' AND time <= '${H_START}' GROUP BY entity_id"
  elif [[ "$MODE" == "LIVE" ]]; then    #live energy
    QUERY="SELECT MIN(value) as produced FROM autogen.${UNITS} WHERE (${or_entities}) AND time >= '${T_START}' GROUP BY entity_id"
  else                                  #power
    QUERY="SELECT FIRST(value) FROM autogen.${UNITS} WHERE (${or_entities}) AND time >= '${H_START}' and time <= '${H_END}'  GROUP BY entity_id"
  fi
  #strip out lifetime_, fill with 0 when missing, write
  queryflux | jq -s -r '.[0].results[0].series[]? | { ((.tags.entity_id | sub("^lifetime_"; ""))): (.values[0][1] // 0 | tonumber ) }' | jq -s add > "$PANELS_OUT"
}

if [[ "$1" == "--discover" ]]; then
  discover
  exit 0
fi


while getopts ":d:h:e:p:m:" opt; do
  case $opt in
    d) DATE="$OPTARG" ;;        # YYYY-MM-DD
    h) HOUR="$OPTARG" ;;        # HH
    e) ENTITY="$OPTARG" ;;      # power_#  (stdout only)
    p) POLL="${OPTARG^^}" ;;    # max | mean | last
    m) MODE="${OPTARG^^}" ;;    # power | energy | live
    \?) echo "Invalid option: -$OPTARG" >&2 ; exit 1 ;;
  esac
done

if [[ -z "$DATE" || -z "$HOUR" ]]; then
  usage
  exit 1
fi

if [[ $HOUR =~ ^[0-9]+$ ]]; then  #busy box date
  if (( HOUR > 23 )); then
    HOUR=23
  fi
else
  echo "HOURS is not a valid number"
  usage
  exit 1
fi

: "${POLL:=MEAN}"  #default to mean
: "${MODE:=POWER}" #default to power


case $MODE in
   "POWER") UNITS="kW"
               EN="";;
  "ENERGY") UNITS="kWh"
               EN="lifetime_" ;;
    "LIVE") UNITS="kWh"                    #LIVE ENERGY
               EN="lifetime_" ;;
         *) echo "Invalid mode: $MODE";
            usage
            exit 1;;
esac

H_START=$(date -u -d "@$(date -d "${DATE} ${HOUR}:00:00" +%s)" +"%Y-%m-%dT%H:%M:%SZ")  # 15 min allowance for slow pollers
  H_END=$(date -u -d "@$(date -d "${DATE} ${HOUR}:15:00" +%s)" +"%Y-%m-%dT%H:%M:%SZ")

D_START=$(date -u -d "@$(date -d "${DATE} 00:00:00" +%s)" +"%Y-%m-%dT%H:%M:%SZ")
  D_END=$(date -u -d "@$(date -d "${DATE} 23:59:59" +%s)" +"%Y-%m-%dT%H:%M:%SZ")

  TODAY=$(date  +"%Y-%m-%d")
T_START=$(date -u -d "@$(date -d "${TODAY} 00:00:00" +%s)" +"%Y-%m-%dT%H:%M:%SZ")

if [ -n "$ENTITY" ]; then   #tests
  if [[ "$MODE" == "ENERGY" || "$MODE" == "LIVE" ]]; then
      ENTITY="${ENTITY/power/lifetime_power}"
  fi
  QUERY="SELECT ${POLL}(value) FROM autogen.${UNITS} WHERE entity_id = '${ENTITY}' AND time >= '${H_START}' AND time <= '${H_END}'"
  queryflux | jq -r '.results[0].series[0].values[0][1] // 0' 2>/dev/null || echo "0"

else
  writegraph
  writepanels
fi

exit 0
