#!/bin/bash

####Config####
INFLUXDB_HOST="localhost:8086"
     USERNAME="powermonitor"
     PASSWORD="password"
     DATABASE="homeassistant"

     DATA_DIR="/config/power"  ### files written by this script
     ENTITIES="${DATA_DIR}/entities.txt"
    GRAPH_OUT="${DATA_DIR}/graph.json"
   PANELS_OUT="${DATA_DIR}/panels.json"

  INTEGRATION=""  ### defaults to "hass-sunpower" (https://github.com/krbaker/hass-sunpower).
                  ### override with "pvs-hass" (https://github.com/SunStrong-Management/pvs-hass)
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
  local query_result
  if query_result=$(curl -sG http://${INFLUXDB_HOST}/query \
    --data-urlencode "db=${DATABASE}" \
    --data-urlencode "u=${USERNAME}" \
    --data-urlencode "p=${PASSWORD}" \
    --data-urlencode "q=${QUERY}"); then
    echo "$query_result"
  else
    echo "Query failed. Is InfluxDB running?"
  fi
}

discover() {
  echo ""
  echo "Expecting integration '$INTEGRATION'"
  echo "Discovering $EN and matching $PW sensors..."

  QUERY='SHOW TAG VALUES FROM "kWh" WITH KEY = "entity_id"'
  readarray -t lifetime_entities < <(queryflux | jq -r '.results[0].series[0].values[][1] // empty' | grep -E "$INVERTER|${METER}${EN_METER}")

  if [ ${#lifetime_entities[@]} -eq 0 ]; then
    echo "No entities found."
    exit 0
  else
    echo ""
    echo "Use below in configuration.yaml for the timelapse_power_panels json_attributes"
    echo ""
  fi

  echo "" > "${ENTITIES}"
  for lifetime_entity in "${lifetime_entities[@]}"; do

   # if [[ ! "$lifetime_entity" =~ (${EN}|${METER}) ]]; then
   #   continue
   # fi

    power_entity="${lifetime_entity/${EN}/${PW}}"
    power_entity="${lifetime_entity/${EN_METER}/${PW_METER}}"

    QUERY="SELECT * FROM \"kW\" WHERE \"entity_id\" = '$power_entity' LIMIT 1"
    result=$(queryflux)

    if echo "$result" | jq -e '.results[0].series[0].values and (.results[0].series[0].values | length > 0)' > /dev/null 2>&1; then
      #echo "Found $power_entity matched from $lifetime_entity"
      echo "- $power_entity" >> "${ENTITIES}"
      echo "        - $power_entity"
    fi
  done
  
  echo ""
  echo "Use above in configuration.yaml for the timelapse_power_panels json_attributes"
  echo "Saved at $ENTITIES"
}

writegraph () {
  local entity
  if [[ -s "$ENTITIES" ]]; then
    local meter
    meter=$(sed 's/^- //' "$ENTITIES" | grep -E "${METER}${PW_METER}" | head -n 1)
    if [[ -n "$meter" ]]; then
      #echo "Using $ENTITIES"
      entity="$meter"
    else
      entity="power"  ###NO MATCH, OVERRIDE THE MAIN POWER ENTITY HERE.
    fi
  fi
  if [[ "$MODE" == "ENERGY" || "$MODE" == "LIVE" ]]; then
      entity="${entity/${PW_METER}/${EN_METER}}"
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
      for i in "${!entities[@]}"; do
         if [[ "${entities[i]}" =~ ${METER}${PW_METER} ]]; then
          entities[i]="${entities[i]/${PW_METER}/${EN_METER}}"
         else
          entities[i]="${entities[i]/${PW}/${EN}}"
         fi
      done
    fi
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
  queryflux | jq -s -r '.[0].results[0].series[]? | { ((.tags.entity_id | sub("lifetime_"; ""))): (.values[0][1] // 0 | tonumber ) }' | jq -s add > "$PANELS_OUT"
}



: "${INTEGRATION:=hass-sunpower}"
case $INTEGRATION in
   "hass-sunpower")    METER="power_meter_.*p_"
                    EN_METER="lifetime_power"
                    PW_METER="power"
                          EN="lifetime_power"
                          PW="power"
                    INVERTER="inverter_*_lifetime_power";;

        "pvs-hass")    METER="meter_.*p_"
                    EN_METER="net_lifetime_energy"
                    PW_METER="3_phase_power"
                          EN="lifetime_production"
                          PW="current_power_production"
                    INVERTER="mi_.*_lifetime_production";;

          "custom")    METER=""
                    EN_METER="lifetime_power"
                    PW_METER="power"
                          EN="lifetime_power"
                          PW="power"
                    INVERTER="lifetime_power_.*";;

                 *) echo "Invalid integration $INTEGRATION";
                    usage
                    exit 1;;
esac

mkdir -p $DATA_DIR

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

HOUR=$((10#$HOUR))

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
   "POWER") UNITS="kW" ;;
  "ENERGY") UNITS="kWh";;
    "LIVE") UNITS="kWh";;              #LIVE ENERGY
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
