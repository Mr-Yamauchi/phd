#!/bin/bash
. ${PHDCONST_ROOT}/lib/transport_ssh.sh

LOG_ERR="error"
LOG_ERROR="error"
LOG_NOTICE="notice"
LOG_INFO="info"
LOG_DEBUG="debug"

PHD_LOG_LEVEL=2
PHD_LOG_STDOUT=1
PHD_TMP_DIR="/var/run/phd_scenario"

LOG_UNAME=""

phd_clear_vars()
{
	local prefix=$1
	local tmp

	if [ -z "$prefix" ]; then
		phd_log LOG_ERR "no variable prefix provided"
		return 1
	fi

	for tmp in $(printenv | grep -e "^${prefix}_*" | awk -F= '{print $1}'); do
		unset $tmp
	done

	return 0
}

phd_get_value()
{
	local value=$1

	if [ "${value:0:1}" = "\$" ]; then
		echo $(eval echo $value)
		return
	fi
	echo $value
}

phd_time_stamp()
{
	date +%b-%d-%T
}

phd_log()
{
	local priority=$1
	local msg=$2
	local node=$3
	local level=1
	local log_msg
	local enable_log_stdout=$PHD_LOG_STDOUT

	if [ -z "$msg" ]; then
		return
	fi

	if [ -z "$LOG_UNAME" ]; then
		LOG_UNAME=$(uname -n)
	fi

	if [ -z "$node" ]; then
		node=$LOG_UNAME
	fi

	case $priority in
	LOG_ERROR|LOG_ERR|LOG_WARNING) level=0;;
	LOG_NOTICE) level=1;;
	LOG_INFO) level=2;;
	LOG_DEBUG) level=3;;
	LOG_TRACE) level=4;;
	# exec output can only be logged to files
	LOG_EXEC) level=5; enable_log_stdout=0;;
	*) phd_log LOG_WARNING "!!!WARNING!!! Unknown log level ($priority)"
	esac

	log_msg="$priority: $node: $(basename ${BASH_SOURCE[1]})[$$]:${BASH_LINENO} - $msg"
	if [ $level -le $PHD_LOG_LEVEL ]; then
		if [ $enable_log_stdout -ne 0 ]; then
			echo "$log_msg"
		fi
	fi

	# log everything to log file
	if [ -n "$PHD_LOG_FILE" ]; then
		echo "$(phd_time_stamp): $log_msg" >> $PHD_LOG_FILE
	fi
}

phd_set_exec_dir()
{
	PHD_TMP_DIR=$1
	if [ -z "$PHD_LOG_FILE" ]; then
		phd_set_log_file "${PHD_TMP_DIR}/phd.log"
	fi
	phd_log LOG_NOTICE "logfile=$PHD_LOG_FILE"
}

phd_enable_stdout_log()
{
	PHD_LOG_STDOUT=$1
}

phd_set_log_level()
{
	PHD_LOG_LEVEL="$1"
}

phd_set_log_file()
{
	PHD_LOG_FILE="$1"
	phd_log LOG_NOTICE "Writing to logfile at $1"
}

phd_cmd_exec()
{
	local cmd=$1
	local nodes=$2
	local node
	local rc=1
	local output=""


	# execute locally if no nodes are given
	if [ -z "$nodes" ]; then
		phd_log LOG_EXEC "$cmd"
		output=$(eval $cmd 2>&1)
		rc=$?

		if [ -n "$output" ]; then
			echo $output
			phd_log LOG_EXEC "$output"
		fi
	else
		# TODO - support multiple transports
		for node in $(echo $nodes); do
			phd_log LOG_EXEC "$node - $cmd"
			output=$(phd_ssh_cmd_exec "$cmd" "$node" 2>&1)
			rc=$?

			if [ -n "$output" ]; then
				echo $output
				phd_log LOG_EXEC "$output" "$node"
			fi
			if [ $rc -eq 137 ]; then
				phd_exit_failure "Timed out waiting for cmd ($cmd) to execute on node $node"
			fi
		done
	fi

	return $rc
}

phd_node_cp()
{
	local src=$1
	local dest=$2
	local nodes=$3
	local permissions=$4
	local node
	
	# TODO - support multiple transports
	for node in $(echo $nodes); do
		phd_log LOG_DEBUG "copying file \"$src\" to node \"$node\" destination location \"$dest\""
		phd_ssh_cp "$src" "$dest" "$node"
		if [ $? -ne 0 ]; then
			phd_log LOG_ERR "failed to copy file \"$src\" to node \"$node\" destination location \"$dest\""
			return 1
		fi
		if [ -n "$permissions" ]; then
			phd_cmd_exec "chmod $permissions $dest" "$node"
		fi
	done

	return 0
}

phd_script_exec()
{
	local script=$1
	local dir=$(dirname $script)
	local nodes=$2
	local node

	for node in $(echo $nodes); do
		phd_log LOG_DEBUG "executing script \"$script\" on node \"$node\""		
		phd_cmd_exec "mkdir -p $dir" "$node" > /dev/null 2>&1
		phd_node_cp "$script" "$script" "$node" "755" > /dev/null 2>&1
		phd_cmd_exec "$script" "$node" > /dev/null 2>&1
	done
}

phd_exit_failure()
{
	local reason=$1

	if [ -z "$reason" ]; then
		reason="scenario failure"
	fi

	phd_log LOG_ERR "Exiting: $reason"
	exit 1
}

phd_test_assert()
{
	if [ $1 -ne $2 ]; then
		phd_log LOG_NOTICE "========================="
		phd_log LOG_NOTICE "====== TEST FAILURE ====="
		phd_log LOG_NOTICE "========================="
		phd_exit_failure "unexpected exit code $1, $3"
	fi	
}

phd_wait_pidof()
{
	local pidname=$1
	local timeout=$2
	local lapse_sec=0
	local stop_time=0

	if [ -z "$timeout" ]; then
		timeout=60
	fi

	stop_time=$(date +%s)
	pidof $pidname 
	while [ "$?" -ne "0" ]; do
		lapse_sec=`expr $(date +%s) - $stop_time`
		if [ $lapse_sec -ge $timeout ]; then
			phd_exit_failure "Timed out waiting for $pidname to start"
		fi

		sleep 1
		pidof $pidname
	done

	return 0
}
