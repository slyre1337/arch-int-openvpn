#!/bin/bash

# check that app requires port forwarding and vpn provider is pia (note this env var is passed through to up script via openvpn --sentenv option)
if [[ "${APPLICATION}" != "sabnzbd" ]] && [[ "${APPLICATION}" != "privoxy" ]] && [[ "${VPN_PROV}" == "pia" ]]; then

	if [[ "${STRICT_PORT_FORWARD}" == "no" ]]; then

		echo "[info] Port forwarding is not enabled"

		# create empty incoming port file (read by downloader script)
		touch /tmp/getvpnport

	else

		echo "[info] Port forwarding is enabled"

		####
		# check endpoint is port forward enabled
		####

		echo "[info] Checking endpoint '${VPN_REMOTE}' is port forward enabled..."

		# pia api url for endpoint status (port forwarding enabled true|false)
		pia_vpninfo_api="https://www.privateinternetaccess.com/vpninfo/servers?version=82"

		# jq (json query tool) query to select port forward and filter based only on port forward being enabled (true)
		jq_query_filter_portforward='.[] | select(.port_forward|tostring | contains("true"))'

		# run curly to grab api result
		rm -f "/tmp/piasupportportforwardapi"
		curly.sh -ct 10 -rc 12 -of "/tmp/piasupportportforwardapi" -url "${pia_vpninfo_api}"

		if [[ "${?}" != 0 ]]; then

			echo "[warn] PIA VPN info API currently down, skipping endpoint port forward check"

		else

			# run jq query with the filter
			jq_query_result=$(cat "/tmp/piasupportportforwardapi" | jq -r "${jq_query_filter_portforward}" 2> /dev/null)

			# run jq query to get endpoint name (dns) only, use xargs to turn into single line string
			jq_query_details=$(echo "${jq_query_result}" | jq -r '.dns' | xargs)

			# run grep to check that defined vpn remote is in the list of port forward enabled endpoints
			# grep -w = exact match (whole word), grep -q = quiet mode (no output)
			echo "${jq_query_details}" | grep -qw "${VPN_REMOTE}"

			if [[ "${?}" != 0 ]]; then

				echo "[warn] PIA endpoint '${VPN_REMOTE}' is not in the list of endpoints that support port forwarding, DL/UL speeds maybe slow"
				echo "[info] Please consider switching to one of the endpoints shown below"

			else

				echo "[info] PIA endpoint '${VPN_REMOTE}' is in the list of endpoints that support port forwarding"

			fi

			# convert to list with separator being space
			IFS=' ' read -ra jq_query_details_list <<< "${jq_query_details}"

			echo "[info] List of PIA endpoints that support port forwarding:-"

			# loop over list of port forward enabled endpooints and echo out to console
			for i in "${jq_query_details_list[@]}"; do
					echo "[info] ${i}"
			done

		fi

		####
		# get dynamically assigned port number
		####

		echo "[info] Attempting to get dynamically assigned port..."

		# pia api url for getting dynamically assigned port number
		pia_vpnport_api_host="209.222.18.222"
		pia_vpnport_api_port="2000"
		pia_vpnport_api="http://${pia_vpnport_api_host}:${pia_vpnport_api_port}"

		# create pia client id (randomly generated)
		client_id=$(head -n 100 /dev/urandom | sha256sum | tr -d " -")

		# run curly to grab api result
		rm -f "/tmp/piaportassignapi"
		curly.sh -ct 10 -rc 12 -of "/tmp/piaportassignapi" -url "${pia_vpnport_api}/?client_id=${client_id}"

		if [[ "${?}" != 0 ]]; then

			echo "[warn] PIA VPN port assignment API currently down, terminating OpenVPN process to force retry for incoming port..."
			kill -2 $(cat /root/openvpn.pid)
			exit 1

		else

			VPN_INCOMING_PORT=$(cat /tmp/piaportassignapi | jq -r '.port')

			if [[ "${VPN_INCOMING_PORT}" =~ ^-?[0-9]+$ ]]; then

				echo "[info] Successfully assigned incoming port ${VPN_INCOMING_PORT}"

				# write port number to text file (read by downloader script)
				echo "${VPN_INCOMING_PORT}" > /tmp/getvpnport

			else

				echo "[warn] PIA VPN assigned port is malformed, terminating OpenVPN process to force retry for incoming port..."
				kill -2 $(cat /root/openvpn.pid)
				exit 1

			fi

		fi

		# chmod file to prevent restrictive umask causing read issues for user nobody (owner is user root)
		chmod +r /tmp/getvpnport

	fi

else
	
	# get internal perfect privacy IP (from interface "tun0")
	interface_name=tun0
	IPv4_ADDR=$(
	    ip a s dev $interface_name |
		awk '/inet /{gsub("/.*", "");print $2}'
	)
	
	echo "[info]  ---------------------------------------- Perfect Privacy --- OpenVPN config --- Found internal IP from dev=tun0: $IPv4_ADDR"
	
	# convert internal IP into Port
	IFS='.' read -ra ADDR <<< "$IPv4_ADDR"
	function d2b() {
		printf "%08d" $(echo "obase=2;$1"|bc)
	}
	port_bin="$(d2b ${ADDR[2]})$(d2b ${ADDR[3]})"
	port_dec=$(printf "%04d" $(echo "ibase=2;${port_bin:4}"|bc))
	for i in 1; do
	
		# set calculated port as port variable to add to qbittorrent config 
		VPN_INCOMING_PORT=$i$port_dec
	done
	
	echo "[info] ---------------------------------------- Perfect Privacy --- OpenVPN config --- Calculated the port: $VPN_INCOMING_PORT"
	echo "${VPN_INCOMING_PORT}" > /tmp/getvpnport

fi
