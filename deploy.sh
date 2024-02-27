#!/bin/bash
if [ ! -f ".env" ]
then
  echo "File .env does not exist."
  exit 1
fi
source .env

if [ -z "$PRIVATE_KEY" ]
then
  echo "PRIVATE_KEY is not set in .env"
  exit 1
fi
first_2_chars=${PRIVATE_KEY:0:2}
if [ "$first_2_chars" != "0x" ]
then
  echo "Add "0x" to the beggining of your PRIVATE_KEY in .env"
  exit 1
fi

if ! command -v forge &> /dev/null
then
  echo "forge could not be found"
  exit 1
fi

if [ -z "$1" ]
then
  echo "Incorrect Usage, please use: ./deploy.sh <network> <simulation=true>"
  exit 1
fi
network=${1^^}

if [ -z "$2" ]
then
  echo "Test arg was not set, so we will assume true: ./deploy.sh <network> <simulation=true>"
  is_sim=true
fi
is_sim=${2}

if [ "${3^^}" == "COPY" ]
then
  mode="COPY"
else
  mode="EXECUTE"
fi

rpc="ETH_NODE_URI_$network"
rpc_uri=$(grep $rpc .env | cut -d '=' -f2-)
if [ -z "$rpc_uri" ]
then
  echo "ETH_NODE_URI_$network is not set in .env"
  exit 1
fi

network=${network,,}
script="script ./script/DeployCurvance.s.sol \"$network\" --sig \"run(string)\" --rpc-url $rpc_uri"
if [ "${is_sim^^}" == "FALSE" ] || [ "$is_test" == "0" ]
then
  echo "Deploying to $network"
  script="forge ${script} --broadcast -vvvv"
else
  echo "Deploying to $network [TEST-RUN]"
  script="forge ${script} -vvvv"
fi

if [ $mode == "COPY" ]
then
  echo $script | xclip -selection c
  echo "Copied to clipboard: $script"
else
  eval $script
fi

exit 0
