#!/bin/bash
/usr/sbin/sshd -D &

PATH="$PATH:/opt/openmpi/bin/"
BASENAME="${0##*/}"

# location of this script to call related tools
SCRIPT=$(readlink -e "$0")
SCRIPTDIR=$(dirname "$SCRIPT")

# Default location is defined by environment variable INPUT_CNF
INPUT_CNF="${INPUT_CNF:-}"
SOLVER_TIMEOUT_S="${SOLVER_TIMEOUT_S:-28800}"
declare -a BASE_SOLVER=("/hordesat/hordesat-src/hordesat" "-t=${SOLVER_TIMEOUT_S}")


log () {
  echo "${BASENAME} - ${1}"
}

HOST_FILE_PATH="/tmp/hostfile"

# Be able to handle local input, outside of AWS batch
NODE_TYPE="single"

# If no local CNF, allow to participate in AWS BATCH cluser
if [ -z "$INPUT_CNF" ]
then
    if ! command -v aws &> /dev/null
    then
        echo "error: cannot find tool 'aws', abort"
        exit 1
    fi

    echo "Downloading problem from S3: ${COMP_S3_PROBLEM_PATH}"
    if [[ "${COMP_S3_PROBLEM_PATH}" == *".xz" ]];
    then
      aws s3 cp s3://${S3_BKT}/${COMP_S3_PROBLEM_PATH} test.cnf.xz
      unxz test.cnf.xz
    else
      aws s3 cp s3://${S3_BKT}/${COMP_S3_PROBLEM_PATH} test.cnf
    fi
    INPUT_CNF=$(readlink -e test.cnf)

    # evaluate AWS
    sleep 2
    AWS_BATCH_JOB_MAIN_NODE_INDEX="${AWS_BATCH_JOB_MAIN_NODE_INDEX:-}"
    AWS_BATCH_JOB_NODE_INDEX="${AWS_BATCH_JOB_NODE_INDEX:-}"

    # if AWS_BATCH variables are set, use them to evaluate own position in MPI
    if [ -n "$AWS_BATCH_JOB_MAIN_NODE_INDEX" ] || [ -n "$AWS_BATCH_JOB_NODE_INDEX" ]
    then
        echo main node: ${AWS_BATCH_JOB_MAIN_NODE_INDEX}
        echo this node: ${AWS_BATCH_JOB_NODE_INDEX}
        # Set child by default switch to main if on main node container
        NODE_TYPE="child"
        if [ "${AWS_BATCH_JOB_MAIN_NODE_INDEX}" == "${AWS_BATCH_JOB_NODE_INDEX}" ]; then
          log "Running synchronize as the main node"
          NODE_TYPE="main"
        fi
    fi
else
    # if we are not in an AWS batch cluster, assume we are the only node
    AWS_BATCH_JOB_MAIN_NODE_INDEX="1"
    AWS_BATCH_JOB_NODE_INDEX="1"
    AWS_BATCH_JOB_NUM_NODES="1"
fi



# wait for all nodes to report
wait_for_nodes () {
  log "Running as master node"

  touch $HOST_FILE_PATH
  ip=$(/sbin/ip -o -4 addr list eth0 | awk '{print $4}' | cut -d/ -f1)

  availablecores=$(nproc)
  log "master details -> $ip:$availablecores"
  log "main IP: $ip"
#  echo "$ip slots=$availablecores" >> $HOST_FILE_PATH
  echo "$ip" >> $HOST_FILE_PATH
  lines=$(ls -dq /tmp/hostfile* | wc -l)
  while [ "${AWS_BATCH_JOB_NUM_NODES}" -gt "${lines}" ]
  do
    cat $HOST_FILE_PATH
    lines=$(ls -dq /tmp/hostfile* | wc -l)

    log "$lines out of $AWS_BATCH_JOB_NUM_NODES nodes joined, check again in 1 second"
    sleep 1
#    lines=$(sort $HOST_FILE_PATH|uniq|wc -l)
  done


  # All of the hosts report their IP and number of processors. Combine all these
  # into one file with the following script:
  "$SCRIPTDIR"/make_combined_hostfile.py ${ip}
  cat combined_hostfile

  # REPLACE THE FOLLOWING LINE WITH YOUR PARTICULAR SOLVER
  time mpirun --mca btl_tcp_if_include eth0 --allow-run-as-root -np ${AWS_BATCH_JOB_NUM_NODES} --hostfile combined_hostfile \
      "${BASE_SOLVER[@]}" "$INPUT_CNF"
}


# solve CNF in INPUT_CNF
solve_single ()
{
    # hordesat will automatically pick the number of available cores
    "${BASE_SOLVER[@]}" "$INPUT_CNF"
    return $?
}

# Fetch and run a script
report_to_master () {
  # get own ip and num cpus
  #
  ip=$(/sbin/ip -o -4 addr list eth0 | awk '{print $4}' | cut -d/ -f1)


  availablecores=$(nproc)

  log "I am a child node -> $ip:$availablecores, reporting to the master node -> ${AWS_BATCH_JOB_MAIN_NODE_PRIVATE_IPV4_ADDRESS}"

#  echo "$ip slots=$availablecores" >> $HOST_FILE_PATH${AWS_BATCH_JOB_NODE_INDEX}
  echo "$ip" >> $HOST_FILE_PATH${AWS_BATCH_JOB_NODE_INDEX}
  ping -c 3 ${AWS_BATCH_JOB_MAIN_NODE_PRIVATE_IPV4_ADDRESS}
  until scp $HOST_FILE_PATH${AWS_BATCH_JOB_NODE_INDEX} ${AWS_BATCH_JOB_MAIN_NODE_PRIVATE_IPV4_ADDRESS}:$HOST_FILE_PATH${AWS_BATCH_JOB_NODE_INDEX}
  do
    echo "Sleeping 5 seconds and trying again"
  done
  log "done! goodbye"
  ps -ef | grep sshd
  tail -f /dev/null
}
##
#
# Main - dispatch user request to appropriate function
log $NODE_TYPE
case $NODE_TYPE in
  main)
    wait_for_nodes "${@}"
    exit $?
    ;;

  child)
    report_to_master "${@}"
    exit $?
    ;;
  single)
    solve_single "${@}"
    exit $?
    ;;
  *)
    log $NODE_TYPE
    usage "Could not determine node type. Expected (main/child)"
    ;;
esac
