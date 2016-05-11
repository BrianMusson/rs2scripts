#!/bin/bash

# Size of the object to create
objectsize=8KB

# File with the list of node IPs
connectors=~/scality.nodes

# Number of objects to create in the bucket
bucket_objects=10

# Number of times to run the test loop
max_runs=50

# s3cfg configuration file to use
s3cfg=~/.s3cfg

# Allocate the file
fallocate -l $objectsize /tmp/object

# Exit control
die() 
{
	printf "!!! %s\n" "$@"
	s3cmd_do rb s3://$bucket -r --force
	exit 1
}

# Wrap s3cmd for better handling, discard output
s3cmd_do()
{
	s3cmd -c $s3cfg "$@" > /dev/null || die "$@"
}

# Raw s3cmd wrapper for commands that need to preserve output
s3cmd_raw()
{
	s3cmd -c $s3cfg "$@" || die "$@"
}

main_loop()
{
	# Start the testing loop
	local runs=1
	while [[ $runs -le $max_runs ]]; do
		printf "*** Starting %s of %s:\n" "$runs" "$max_runs"
	
		# Create the bucket
		bucket="testbucket"$(date +%s)
		printf "*** Creating bucket %s\n" "$bucket"
		s3cmd_do mb s3://$bucket
	
		# Put the objects into the bucket
		printf "*** Creating objects in %s: " "$bucket"
		local object_num=1
		while [[ $object_num -le $bucket_objects ]]; do
			printf "."
			if [[ $(expr $object_num % 5) -eq 0 ]]; then
				printf "%d" "$object_num"
			fi
			s3cmd_do put /tmp/object s3://$bucket/$object$object_num
			let object_num+=1
		done
	
		# Record the bucket's size
		local disk_usage=( $(s3cmd_raw du s3://$bucket) )
		
		# Verify that the correct number of objects were put (expected vs real)
		[[ ${disk_usage[1]} -eq $bucket_objects ]] || die "Was expecting $bucket_objects objects in $bucket but only found ${disk_usage[1]}"
		
		# Delete the objects from the bucket
		printf "\n*** Removing objects from %s: " "$bucket"
		let object_num=1
		while [[ $object_num -le $bucket_objects ]]; do
			printf "."
			if [[ $(expr $object_num % 5) -eq 0 ]]; then
				printf "%d" "$object_num"
			fi
			s3cmd_do del s3://$bucket/$object$object_num
			let object_num+=1
		done
		
		# Delete the bucket
		printf "\n*** Removing bucket %s\n" "$bucket"
		s3cmd_do rb s3://$bucket

  		# Search all of the nodes for this bucket entry
		local count=0
		while read host; do
			occurrences=$(ssh $host grep $bucket /var/log/scality-rest-connector/restapi.log < /dev/null | wc -l)
			if [[ $occurrences -ge 1 ]]; then
				printf "*** %s has %d entries for %s\n" "$host" "$occurrences" "$bucket"
				let count+=1
				local hostlist="$hostlist $host"
			fi
		done < $connectors
	
		# If we have more than one log entry for a particular bucket on multiple
		# hosts, then we know that bucket persistence is not functioning correctly.
		if [[ $count > 1 ]]; then
			die "More than one host has an entry for this bucket: $hostlist"
		elif [[ $count == 0 ]]; then
			die "Could not locate any entries on any of the hosts! is logging configured?" \
				"check /var/log/scality-rest-connector/restapi.log for more information."
		else
			printf "*** Test %d of %d complete\n" "$runs" "$max_runs"
		fi

		let runs+=1
	done
}

# Run the main loop
main_loop && printf "*** Finished.\n"
