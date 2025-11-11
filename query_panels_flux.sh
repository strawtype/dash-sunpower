#!/bin/bash

####Config####
INFLUXDB_HOST="{IP}:8086"
     PASSWORD="{TOKEN}" ### API token
     BUCKET="{DATA_BCKET}" ### InfluxDB 2.0 BucketName where home_assistant data is stored
     ORG="{ORGID}" ### InlfuxDB 2.0 OrgId

     DATA_DIR="/config/power"  ### files written by this script
     ENTITIES="${DATA_DIR}/entities.txt"
    GRAPH_OUT="${DATA_DIR}/graph.json"
   PANELS_OUT="${DATA_DIR}/panels.json"

  INTEGRATION="pvs-hass"  ### "hass-sunpower" (https://github.com/krbaker/hass-sunpower). (default)
                  ### "pvs-hass" (https://github.com/SunStrong-Management/pvs-hass)
                  ### "custom"   (see below)
                  ### always run --discover after changing INTEGRATION

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
  if query_result=$(curl -sXPOST http://${INFLUXDB_HOST}/api/v2/query?org=${ORG} \
    -H "Authorization: Token ${PASSWORD}" \
    -H "Content-Type: application/vnd.flux" \
    -H "Accept: application/csv" \
    -d "${QUERY}"); then
    echo "$query_result"
  else
    echo "Query failed. Is InfluxDB running?"
  fi
}

discover() {
  echo ""
  echo "Expecting integration '$INTEGRATION'"
  echo "Discovering $EN and matching $PW sensors..."

  QUERY='from(bucket: "'"${BUCKET}"'")
  |> range(start: -30d)
  |> filter(fn: (r) => r._measurement == "kWh")
  |> keep(columns: ["entity_id"])
  |> distinct(column: "entity_id")'
  readarray -t lifetime_entities < <(queryflux | cut -d',' -f4 | sort -u | grep -E "$INVERTER|${METER}${EN_METER}")
  
  if [ ${#lifetime_entities[@]} -eq 0 ]; then
    echo "No entities found."
    exit 0
  else
    echo ""
    echo "Use below in configuration.yaml for the timelapse_power_panels json_attributes"
    echo ""
  fi

  #echo "" > "${ENTITIES}"
  for lifetime_entity in "${lifetime_entities[@]}"; do

    if [[ "$lifetime_entity" =~ ${METER}${EN_METER} ]]; then
      power_entity="${lifetime_entity/${EN_METER}/${PW_METER}}"
    else
      power_entity="${lifetime_entity/${EN}/${PW}}"
    fi

    QUERY='from(bucket: "'"${BUCKET}"'")
        |> range(start: -1d)
        |> filter(fn: (r) => r._measurement == "kW" and r.entity_id == "'"${power_entity}"'")
        |> limit(n: 1)'
    
    result=$(queryflux)
    if echo "$result" | tail -n +2 | grep -q .; then
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
      entity="$meter"
    else
      entity="power"  ###NO MATCH, OVERRIDE THE MAIN POWER ENTITY HERE.
    fi
  fi
  if [[ "$MODE" == "ENERGY" || "$MODE" == "LIVE" ]]; then
      entity="${entity/${PW_METER}/${EN_METER}}"
  fi

  QUERY='from(bucket: "'"${BUCKET}"'")
      |> range(start: time(v: "'"${D_START}"'"), stop: time(v: "'"${D_END}"'"))
      |> filter(fn: (r) => r._measurement == "'"${UNITS}"'" and r.entity_id == "'"${entity}"'" and r._field == "value")
      |> aggregateWindow(every: 1h, fn: first, createEmpty: true)
      |> fill(value: 0.0)
      |> keep(columns: ["_time", "_value"])
      |> sort(columns: ["_time"])'
  local values
  values=$(queryflux | awk -F',' '
  NR==1 { 
    for(i=1; i<=NF; i++) { 
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", $i)  # trim whitespace
      if($i == "_value") col=i 
    } 
  }
  NR>1 && !/^#/ && NF>0 { 
    val=$col
    gsub(/^[[:space:]]+|[[:space:]]+$/, "", val)  # trim whitespace
    if(val != "") print val
  }' | jq -Rs 'split("\n") | map(select(length > 0) | try tonumber catch 0)')

  if [[ $MODE == "ENERGY" || $MODE == "LIVE" ]]; then
    # Get first non-zero, non-null value as starting point
    start_value=$(echo "$values" | jq '[.[] | select(. != null and . != 0)] | .[0]')
    
    # Calculate incremental differences, handle resets and missing values
    values=$(echo "$values" | jq --argjson start "$start_value" '
      reduce .[] as $end (
        {prev: $start, result: []};
        if ($end == 0 or $end == null) then
          # Use previous result value when zero or missing
          {prev: .prev, result: (.result + [(.result[-1] // 0)])}
        else
          # Calculate difference
          (($end - .prev) | if . < 0 then (.result[-1] // 0) else . end) as $diff |
          {prev: $end, result: (.result + [$diff])}
        end
      ) | .result
    ')
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
  
  # Build filter expression for multiple entities
  local filter_expr=""
  for entity in "${entities[@]}"; do
    if [[ -n "$filter_expr" ]]; then
      filter_expr+=" or "
    fi
    filter_expr+="r.entity_id == \"$entity\""
  done
  
  if [[ "$MODE" == "ENERGY" ]]; then    #energy
    QUERY='from(bucket: "'"${BUCKET}"'")
        |> range(start: time(v: "'"${D_START}"'"), stop: time(v: "'"${H_START}"'"))
        |> filter(fn: (r) => r._measurement == "'"${UNITS}"'" and r._field == "value" and ('${filter_expr}'))
        |> group(columns: ["entity_id"])
        |> reduce(
            fn: (r, accumulator) => ({
              max: if r._value > accumulator.max then r._value else accumulator.max,
              min: if r._value < accumulator.min then r._value else accumulator.min
            }),
            identity: {max: 0.0, min: 999999999.9}
          )
        |> map(fn: (r) => ({"1": r.max - r.min, "2": r.entity_id}))
        |> rename(columns: {"1": "_value", "2": "entity_id"})'
  
  elif [[ "$MODE" == "LIVE" ]]; then    #live energy
    QUERY='from(bucket: "'"${BUCKET}"'")
        |> range(start: time(v: "'"${T_START}"'"))
        |> filter(fn: (r) => r._measurement == "'"${UNITS}"'" and r._field == "value" and ('${filter_expr}'))
        |> group(columns: ["entity_id"])
        |> min()
        |> keep(columns: ["_value", "entity_id"])'
  else                                  #power
    QUERY='from(bucket: "'"${BUCKET}"'")
        |> range(start: time(v: "'"${H_START}"'"), stop: time(v: "'"${H_END}"'"))
        |> filter(fn: (r) => r._measurement == "'"${UNITS}"'" and r._field == "value" and ('${filter_expr}'))
        |> group(columns: ["entity_id"])
        |> first()
        |> keep(columns: ["_value", "entity_id"])'
  fi
  
  # Parse CSV output and convert to JSON
  queryflux | awk -F',' '
  NR==1 {
    # Find column indices in header
    for (i=1; i<=NF; i++) {
      if ($i ~ /entity_id/) entity_col = i;
      if ($i ~ /_value|produced/) value_col = i;
    }
    next;
  }
  entity_col > 0 && value_col > 0 && NF >= entity_col && NF >= value_col {
    gsub(/"/, "", $0);
    gsub(/\r/, "", $0);
    # Skip empty entity_id values
    if ($entity_col != "" && $value_col != "") {
      print $entity_col "," $value_col;
    }
  }' | jq -R -s \
  --arg en "$EN" \
  --arg pw "$PW" \
  --arg enm "$EN_METER" \
  --arg pwm "$PW_METER" '
  split("\n") 
  | map(select(. != "")) 
  | map(split(",") | {(.[0] | sub($en; $pw) | sub($enm; $pwm)): (.[1] | tonumber)})
  | add' > "$PANELS_OUT"
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
    p) POLL="${OPTARG^^}" ;;    # max | mean | first
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

# Convert dates to RFC3339 format for Flux
H_START=$(date -u -d "${DATE} ${HOUR}:00:00" +"%Y-%m-%dT%H:%M:%SZ")
  H_END=$(date -u -d "${DATE} ${HOUR}:15:00" +"%Y-%m-%dT%H:%M:%SZ")

D_START=$(date -u -d "${DATE} 04:00:00" +"%Y-%m-%dT%H:%M:%SZ") ### UTC to EST transform there is betterway to do this
  D_END=$(date -u -d "@$(($(date -d "${DATE} 00:00:00" +%s) + 86400))" +"%Y-%m-%dT04:59:59Z") ### UTC to EST transform there is betterway to do this

  TODAY=$(date  +"%Y-%m-%d")
T_START=$(date -u -d "${TODAY} 04:00:00" +"%Y-%m-%dT%H:%M:%SZ")

if [ -n "$ENTITY" ]; then   #tests
  if [[ "$MODE" == "ENERGY" || "$MODE" == "LIVE" ]]; then
      if [[ "$ENTITY" =~ ${METER}${PW_METER} ]]; then
        ENTITY="${ENTITY/${PW_METER}/${EN_METER}}"
      else
        ENTITY="${ENTITY/${PW}/${EN}}"
      fi
  fi
  
  # Convert POLL to Flux function name
  case $POLL in
    "MAX") POLL_FN="max" ;;
    "MEAN") POLL_FN="mean" ;;
    "FIRST") POLL_FN="first" ;;
    *) POLL_FN="mean" ;;
  esac
  
  QUERY='from(bucket: "'"${BUCKET}"'")
      |> range(start: time(v: "'"${H_START}"'"), stop: time(v: "'"${H_END}"'"))
      |> filter(fn: (r) => r._measurement == "'"${UNITS}"'" and r._field == "value" and r.entity_id == '${ENTITY}')
      |> "'"${POLL_FN}"'"()'

  queryflux | tail -n +2 | cut -d',' -f6 | head -n1 | sed 's/^$/0/'
else
  writegraph
  writepanels
fi

exit 0
