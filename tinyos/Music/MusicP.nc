#include <lib6lowpan/ip.h>
#include "sensing.h"
#include "blip_printf.h"

module MusicP {
	uses {
		interface Boot;
		interface Leds;
		interface SplitControl as RadioControl;

		interface UDP as LightSend;
		interface UDP as Settings;

		interface ShellCommand as GetCmd;
		interface ShellCommand as SetCmd;

		interface Timer<TMilli> as SensorReadTimer;
		interface Read<uint16_t> as ReadPar;

		interface Mount as ConfigMount;
		interface ConfigStorage;
	}
} implementation {

	enum {
		LOW_LIGHT_THRESHOLD = 50,
		PERIOD = 500, // ms
	};

	settings_t settings;
	uint32_t m_seq = 0;
	uint16_t m_par;
	nx_struct sensing_report stats;
	struct sockaddr_in6 route_dest;
	struct sockaddr_in6 multicast;

	event void Boot.booted() {
		settings.light_threshold = LOW_LIGHT_THRESHOLD;

		route_dest.sin6_port = htons(7000);
		inet_pton6(REPORT_DEST, &route_dest.sin6_addr);

		multicast.sin6_port = htons(4000);
		inet_pton6(MULTICAST, &multicast.sin6_addr);
		call Settings.bind(4000);

		call ConfigMount.mount();

		//call RadioControl.start();
	}

	//radio
	event void RadioControl.startDone(error_t e) {
		call SensorReadTimer.startPeriodic(PERIOD);
	}
	event void RadioControl.stopDone(error_t e) {}



	//config

	event void ConfigMount.mountDone(error_t e) {
		if (e != SUCCESS) {
			call Leds.led0On();
			call RadioControl.start();
		} else {
			if (call ConfigStorage.valid()) {
				call ConfigStorage.read(0, &settings, sizeof(settings));
			} else {
				settings.light_threshold = LOW_LIGHT_THRESHOLD;
				call RadioControl.start();
			}
		}
	}

	event void ConfigStorage.readDone(storage_addr_t addr, void* buf, storage_len_t len, error_t e) {
		call RadioControl.start();
	}

	event void ConfigStorage.writeDone(storage_addr_t addr, void* buf, storage_len_t len, error_t e) {
		call ConfigStorage.commit();
	}

	event void ConfigStorage.commitDone(error_t error) {}


	//udp interfaces

	event void LightSend.recvfrom(struct sockaddr_in6 *from, void *data, uint16_t len, struct ip6_metadata *meta) {}

	event void Settings.recvfrom(struct sockaddr_in6 *from, void *data, uint16_t len, struct ip6_metadata *meta) {
		memcpy(&settings, data, sizeof(settings_t));
		call ConfigStorage.write(0, &settings, sizeof(settings));
	}

	//udp shell

	event char *GetCmd.eval(int argc, char **argv) {
		char *ret = call GetCmd.getBuffer(40);
		if (ret != NULL) {
			switch (argc) {
				case 1:
					sprintf(ret, "\t[Threshold: %u]\n", settings.light_threshold);
					break;
				case 2:
					if (!strcmp("th", argv[1])) {
						sprintf(ret, "\t[Threshold: %u]\n",settings.light_threshold);
					} else {
						strcpy(ret, "Usage: get th\n");
					}
					break;
				default:
					strcpy(ret, "Usage: get th\n");
			}
		}
		return ret;
	}

	task void report_settings() {
		call Settings.sendto(&multicast, &settings, sizeof(settings));
		call ConfigStorage.write(0, &settings, sizeof(settings));
	}

	event char *SetCmd.eval(int argc, char **argv) {
		char *ret = call SetCmd.getBuffer(40);
		if (ret != NULL) {
			if (argc == 3) {
				if (!strcmp("th", argv[1])) {
					settings.light_threshold = atoi(argv[2]);
					sprintf(ret, ">>>Threshold changed to %u\n",settings.light_threshold);
				} else {
					strcpy(ret,"Usage: set th <threshold>\n");
				}
			} else if (argc == 4) {
				if (!strcmp("th", argv[1]) && !strcmp("global", argv[3])) {
					settings.light_threshold = atoi(argv[2]);
					sprintf(ret, ">>>Threshold changed globally to %u\n",settings.light_threshold);
					post report_settings();
				} else {
					strcpy(ret,"Usage: set th <threshold> global\n");
				}
			} else {
				strcpy(ret,"Usage: set th <threshold> [global]\n");
			}
		}
		return ret;
	}


	// Light sensor

	event void SensorReadTimer.fired() {
		call ReadPar.read();
	}

	task void report_light() {
		stats.seqno++;
		stats.sender = TOS_NODE_ID;
		stats.light = m_par;
		call LightSend.sendto(&route_dest, &stats, sizeof(stats));
	}

	event void ReadPar.readDone(error_t e, uint16_t data) {
		if (e == SUCCESS) {
			m_par = data;
			if (data < settings.light_threshold) {
				call Leds.set(7);
				post report_light();
			} else {
				call Leds.set(0);
			}
		}
	}
}
