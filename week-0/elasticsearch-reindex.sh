#!/bin/bash
set -x
set -e

declare -A PREFIX
PREFIX["complete-mayor"]="complete"


scriptname=$0
function usage {
    echo ""
    echo "Runs ReIndexing"
    echo ""
    echo "usage: $scriptname --environ staging --prefix complete-mayor --year 2023 --month 03 --new-suffix v4 --old-suffix v3 --cluster-name stories  --batch-size 5000 --ip-address 10.34.4.44 "
    echo ""
    echo "  --environ  string       elasticsearch cluster environment"
    echo "                          (example: staging/prod)"
    echo "  --prefix string         prefix of the index"
    echo "                          (example: complete-mayor)"
    echo "  --year string           4 digit year of the index"
    echo "                          (example: 1969, 2023)"
    echo "  --month string          2 digit month of the index"
    echo "                          (example: 03)"
    echo "  --new-suffix  string     new suffix for the index"
    echo "                          (example: v4)"
    echo "  --old-suffix  string    old suffix for the index"
    echo "                          (example: v3)"
    echo "  --shards  string        number of shards for new index"
    echo "                          (example: 3)"
    echo "  --cluster-name string    dns prefix name of the es cluster"
    echo "                          (example: stories)"
    echo "  --ip-address string     ip address of the query node"
    echo "                          (example: 172.29.203.222)"
    echo "  --batch-size string      size of the indexing batch, defaults to 5000"
    echo "                          (example: 5000)"
    echo "  --index-slices string   size of the slices, defaults to 10"
    echo "                          (example: 5000)"
    echo "  --delete-index string   defaults to false"
    echo "                          (example: true/false)"
    echo ""
}

function die {
    printf "Script failed: %s\n\n" "$1"
    exit 1
}

while [ $# -gt 0 ]; do
    if [[ $1 == "--help" ]]; then
        usage
        exit 0
    elif [[ $1 == "--"* ]]; then
        v=$(echo "${1/--/}" | tr '-' '_')
        declare "$v"="$2"
        shift
    fi
    shift
done

if [[ -z $environ ]]; then
    usage
    die "Missing parameter --environ"
elif [[ -z $prefix ]]; then
    usage
    die "Missing parameter --prefix"
elif [[ -z $year ]]; then
    usage
    die "Missing parameter --year"
elif [[ -z $month ]]; then
    usage
    die "Missing parameter --month"
elif [[ -z $new_suffix ]]; then
    usage
    die "Missing parameter --new-suffix"
elif [[ -z $old_suffix ]]; then
    usage
    die "Missing parameter --old-suffix"
elif [[ -z $cluster_name ]]; then
    usage
    die "Missing parameter --cluster-name"
elif [[ -z $ip_address ]]; then
    usage
    die "Missing parameter --ip-address"
fi

batch_size="${batch_size:-5000}"
index_slices="${index_slices:-10}"
shards="${shards:-3}"
delete_index="${delete_index:-false}"

NEW_INDEX="${prefix}-${year}-${month}-${new_suffix}"
OLD_INDEX="${prefix}-${year}-${month}-${old_suffix}"

# PreIndex for creating the index
python3 -c "import json; data=json.load(open('${environ}-${PREFIX[$prefix]}.json')); data['settings']['number_of_shards'] = $shards; json.dump(data, open('${environ}-${PREFIX[$prefix]}.json', 'w'))"

curl --location --request PUT "http://${cluster_name}.elasticsearch.int.${environ}.mydomaing.com/${NEW_INDEX}" \
-H 'Content-Type: application/json' \
--data-binary "@${environ}-${PREFIX[$prefix]}.json"

curl --location --request PUT "http://${cluster_name}.elasticsearch.int.${environ}.mydomaing.com/${NEW_INDEX}/_settings" \
--header 'Content-Type: application/json' \
--data '{
    "index.routing.allocation.include._tier_preference": null
}'

curl --location --request PUT "http://${cluster_name}.elasticsearch.int.${environ}.mydomaing.com/${NEW_INDEX}/_settings" \
--header 'Content-Type: application/json' \
--data '{
    "index.routing.allocation.include.rack_id": "us-east-1a"
}'

curl --location --request PUT "http://${cluster_name}.elasticsearch.int.${environ}.mydomaing.com/${NEW_INDEX}/_settings" \
-H 'Content-Type: application/json' \
-d '{
    "index.routing.allocation.include._tier_preference": null,
    "index.refresh_interval": "-1"
}'
echo "Updated Settings on New Index ${NEW_INDEX}"

curl -H 'Content-Type: application/json' -XPUT "http://${cluster_name}.elasticsearch.int.${environ}.mydomaing.com/${OLD_INDEX}/_settings" \
-d '{"index.blocks.read_only": "true"}'
echo "Updated Settings on New Index ${OLD_INDEX}"

curl  -H 'Content-Type: application/json' -XPUT "http://${cluster_name}.elasticsearch.int.${environ}.mydomaing.com/${NEW_INDEX}/_settings" \
-d '{ "index": { "number_of_replicas": 0 }}'

# Reindex Command
curl -H 'Content-Type: application/json' -XPOST "http://${ip_address}:9200/_reindex?wait_for_completion=false&slices=${index_slices}" \
-d '{"source": {"index": "'"${OLD_INDEX}"'","size": '"${batch_size}"'},"dest": {"index": "'"${NEW_INDEX}"'"}}'
echo "Triggered ReIndexing  ${OLD_INDEX} ---> ${NEW_INDEX}"

while true; do 
  old_count=$(curl "http://${cluster_name}.elasticsearch.int.${environ}.mydomaing.com/_cat/indices?format=json&index=${OLD_INDEX}"  | jq '.[] | ."docs.count"')
  new_count=$(curl "http://${cluster_name}.elasticsearch.int.${environ}.mydomaing.com/_cat/indices?format=json&index=${NEW_INDEX}"  | jq '.[] | ."docs.count"')
  if [ "${old_count}" = "${new_count}" ]; then
    echo "Old Index Count ${old_count} and New Index ${new_count} are the same";
    break;
  else
    echo "Old Index Count ${old_count} and New Index ${new_count} are different";
    sleep 240;
  fi
done