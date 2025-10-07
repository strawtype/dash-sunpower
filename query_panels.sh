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
   REPORT_OUT="${DATA_DIR}/report.txt"
####Config end###

usage () {
  echo "First time setup run:  $0 --discover"
  echo "Reports:               $0 --report HH"
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
  echo "Discovering lifetime_power and matching power sensors..."

  QUERY='SHOW TAG VALUES FROM "kWh" WITH KEY = "entity_id"'
  readarray -t lifetime_entities < <(queryflux | jq -r '.results[0].series[0].values[][1] // empty' | grep 'lifetime_power')

  if [ ${#lifetime_entities[@]} -eq 0 ]; then
    echo "No lifetime_power entities found."
    exit 0
  else
    echo ""
    echo "Use below in configuration.yaml for the timelapse_power_panels json_attributes"
    echo ""
  fi

  > "${ENTITIES}"
  for lifetime_entity in "${lifetime_entities[@]}"; do
    if [[ "$lifetime_entity" =~ (c_|pv_)(lifetime_)?power$ ]]; then #skip consumption and virtual.  thanks u/babgvant!
      continue
    fi
    power_entity="${lifetime_entity/_lifetime/}"
    power_entity="${power_entity/lifetime_/}"

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

report() {
  local nostats last report results notify
  local now=$(date +%s)
  local start=$((now - (HOUR * 3600)))
  MODE="ENERGY"
  UNITS="kWh"
  H_START=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  D_START=$(date -u -d "@$start" +"%Y-%m-%dT%H:%M:%SZ")

  if [[ -s "$ENTITIES" ]]; then
   nostats=$(writepanels | jq -r 'to_entries[] | select(.value == 0 or .value == null) | .key')


  else
    echo "No entities found.  First time setup run:  $0 --discover"
    echo ""
    exit 0
  fi

  for stat in $nostats; do

    QUERY="SELECT MAX(value) FROM autogen.${UNITS} WHERE entity_id = '${stat}'"
    last=$(queryflux)
    utc=$(echo "$last" | jq -r '.results[0].series[0].values[0][0] // empty' | sed -E 's/\..*Z$//' | tr 'T' ' ')
    epoch=$(date -u -D "%Y-%m-%d %H:%M:%S" -d "$utc" +%s)
    local_t=$(date -d "@$epoch" "+%Y-%m-%d %H:%M:%S")
    value=$(echo "$last" | jq -r '.results[0].series[0].values[0][1] // empty')
    #results+="$stat | Last Update: UTC - $utc , Local - $local_t | Value: $value"$'\n'
    results+="$stat | Last Update: $local_t | Value: $value"$'\n'

  done

  report="$results"
  if [[ -n "$report" ]]; then
       notify="WARN: missing over $HOUR hours of energy statistics from one or more devices"$'\n'
       report="$notify$report"
  fi
  notify=""
  QUERY="SELECT friendly_name_str,LAST(value) FROM s WHERE friendly_name_str =~ /PVS/ GROUP BY friendly_name_str"
  results=$(queryflux)


  #echo "$results" | jq -c '.results[0].series[]?' | while read -r i; do
  while read -r i; do
    last=$(echo "$i" | jq -r '.values[0][0]')
    utc=$(echo "$last" | sed -E 's/\..*Z$//' | tr 'T' ' ')
    epoch=$(date -u -D "%Y-%m-%d %H:%M:%S" -d "$utc" +%s)
    local_t=$(date -d "@$epoch" "+%Y-%m-%d %H:%M:%S")
    age=$((now - epoch))
    if (( age >= 3600 )); then
      notify="CRIT: PVS last update @ $local_t "
    fi
    name=$(echo "$i" | jq -r '.values[0][1]')
    pvs=$(echo "$name" | grep -oE 'PVS[0-9]+')
    serial=$(echo "$name" | grep -oE '[A-Z0-9]{16,}' | tail -n1 | grep -oE '.{5}$')
    name="$pvs-$serial"

    uptime=$(echo "$i" | jq -r '.values[0][2]')
    if [[ uptime -le 600 ]]; then
      notify='INFO: PVS Recent Reboot'
    fi

    if [[ -n "$epoch" && "$uptime" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
      reboot_epoch=$((epoch - ${uptime%.*}))
      reboot_local=$(date -d "@$reboot_epoch" "+%Y-%m-%d %H:%M:%S")
      reboot_utc=$(date -u -d "@$reboot_epoch" "+%Y-%m-%d %H:%M:%S")
    else
      reboot_time="Invalid"
    fi
    #report+="PVS: $name | Last Update: UTC - $utc , Local - $local_t  | Last Reboot: UTC - $reboot_utc , Local - $reboot_local | Uptime: $uptime sec"$'\n'
  done  < <(echo "$results" | jq -c '.results[0].series[]?')

  if [[ -n "$report" || -n "$notify" ]]; then
    echo "$notify"
    report+="$name | Last Update: $local_t  | Last Reboot: $reboot_local | Uptime: $uptime sec"$'\n'
    echo "$report"
  fi
}

writegraph () {
  local entity
  if [[ -s "$ENTITIES" ]]; then
    local power
    power=$(sed 's/^- //' "$ENTITIES" | grep 'power_meter' | head -n 1)
    if [[ -n "$power" ]]; then
      #echo "Using $ENTITIES"
      entity="$power"
    else
      entity="power"  ###NO MATCH, OVERRIDE THE MAIN POWER ENTITY HERE.
    fi
  fi

  if [[ "$MODE" == "ENERGY" || "$MODE" == "LIVE" ]]; then
    if [[ "$entity" == *_power ]]; then
      entity="${entity/_power/_lifetime_power}"
    elif [[ "$entity" == power* ]]; then
      entity="${entity/power/lifetime_power}"  ##legacy, or override
    fi
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
         if [[ "${entities[i]}" == *_power ]]; then
          entities[i]="${entities[i]/_power/_lifetime_power}"
         elif [[ "${entities[i]}" == power* ]]; then
           entities[i]="${entities[i]/power/lifetime_power}"  ##legacy, or override
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
  if [[ "${FUNCNAME[1]}" == "report" ]]; then
      local results merge_results
      results=$(queryflux | jq -s -r '.[0].results[0].series[]? | { (.tags.entity_id): (.values[0][1] // 0 | tonumber) }' | jq -s add)
      merge_results=$(jq -n --argjson polled "$results" --argjson listed "$(printf '%s\n' "${entities[@]}" | jq -R . | jq -s 'reduce .[] as $e ({}; .[$e] = null)')" '$listed + $polled')
      echo "$merge_results"
      return
  fi
  #strip out lifetime_, fill with 0 when missing, write
  queryflux | jq -s -r '.[0].results[0].series[]? | { ((.tags.entity_id | sub("lifetime_"; ""))): (.values[0][1] // 0 | tonumber ) }' | jq -s add > "$PANELS_OUT"
}

mkdir -p $DATA_DIR

if [[ "$1" == "--discover" ]]; then
  discover
  exit 0
fi

if [[ "$1" == "--report" ]]; then
  if [ -n "$2" ]; then
    HOUR="$2"
  fi
  : "${HOUR:=24}"  #default to 24
  report
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
