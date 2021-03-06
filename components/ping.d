/*
 * Copyright (c) 2016-2017 SEL
 * 
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 * 
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
 * See the GNU Lesser General Public License for more details.
 * 
 */
module ping;

import std.algorithm : canFind;
import std.conv : to;
import std.datetime : StopWatch, AutoStart, dur;
import std.json;
import std.socket;
import std.stdio : write;
import std.string;

enum magic = cast(ubyte[])[0x00, 0xFF, 0xFF, 0x00, 0xFE, 0xFE, 0xFE, 0xFE, 0xFD, 0xFD, 0xFD, 0xFD, 0x12, 0x34, 0x56, 0x78];

void main(string[] args) {

	bool has_port = args[1].lastIndexOf(":") > args[1].lastIndexOf("]");
	string ip = args[1].replace("[", "").replace("]", "");
	ushort port = 0;
	if(has_port) {
		string[] spl = ip.split(":");
		ip = spl[0..$-1].join(":");
		port = to!ushort(spl[$-1]);
	}

	// check options
	bool raw = args.canFind("-raw");
	T find(T)(string key, T def) {
		foreach(arg ; args) {
			if(arg.startsWith(key)) {
				try {
					return to!T(arg[key.length..$]);
				} catch(Exception) {}
			}
		}
		return def;
	}
	bool pc = ["pc", "minecraft", "mc"].canFind(find("-game=", "pc"));
	bool pe = ["pe", "pocket", "mcpe"].canFind(find("-game=", "pe"));
	uint send_timeout = find("-send-timeout=", 500);
	uint recv_timeout = find("-recv-timeout=", 3000);

	JSONValue[string] json;

	// Minecraft
	if(pc) {
		try {
			ushort p = port==0 ? 25565 : port;
			Address address = getAddress(ip, p)[0];
			TcpSocket socket = new TcpSocket(address.addressFamily);
			socket.setOption(SocketOptionLevel.SOCKET, SocketOption.REUSEADDR, true);
			socket.setOption(SocketOptionLevel.SOCKET, SocketOption.SNDTIMEO, dur!"msecs"(send_timeout));
			socket.setOption(SocketOptionLevel.SOCKET, SocketOption.RCVTIMEO, dur!"msecs"(recv_timeout));
			socket.connect(address);
			socket.send(cast(ubyte[])[ip.length + 6, 0, 0, ip.length] ~ cast(ubyte[])ip ~ cast(ubyte[])[(p >> 8) & 255, p & 255, 1]);
			socket.send(cast(ubyte[])[1, 0]);
			ubyte[] query;
			ubyte[] buffer = new ubyte[16384];
			ulong ping = 0;
			auto timer = StopWatch(AutoStart.yes);
			ptrdiff_t r = socket.receive(buffer);
			if(r > 0) {
				timer.stop();
				ping = timer.peek.msecs;
				query = buffer[0..r].dup;
				immutable length = readVarint(query);
				while(query.length < length && (r = socket.receive(buffer)) > 0) {
					query ~= buffer[0..r].dup;
				}
			}
			if(readVarint(query) == 0 && readVarint(query) > 0) {
				// recalculate ping
				timer.reset();
				timer.start();
				socket.send(cast(ubyte[])[9, 1, 0, 0, 0, 0, 0, 0, 0, 0]);
				if(socket.receive(buffer) == 10 && buffer[1] == 1) {
					ping = timer.peek.msecs;
				}
				if(raw) {
					json["minecraft"] = cast(string)query;
				} else {
					auto res = parseJSON(cast(string)query).object;
					string name = "";
					if(res["description"].type == JSON_TYPE.OBJECT) {
						if("extra" in res["description"].object) {
							foreach(JSONValue value ; res["description"].object["extra"].array) {
								if("text" in value) {
									name ~= value["text"].str; 
								}
							}
						} else {
							name = res["description"].object["text"].str;
						}
					} else {
						name = res["description"].str;
					}
					JSONValue[string] minecraft;
					minecraft["motd"] = name;
					minecraft["ip"] = ip;
					minecraft["port"] = p;
					minecraft["protocol"] = res["version"].object["protocol"].integer;
					minecraft["version"] = res["version"].object["name"].str;
					minecraft["online"] = res["players"].object["online"].integer;
					minecraft["max"] = res["players"].object["max"].integer;
					minecraft["ping"] = ping;
					if("favicon" in res) minecraft["favicon"] = res["favicon"].str;
					json["minecraft"] = minecraft;
				}
			}
			socket.close();
		} catch(Throwable) {}
	}

	// Minecraft: Pocket Edition
	if(pe) {
		try {
			ushort p = port==0 ? 19132 : port;
			Address address = getAddress(ip, p)[0];
			UdpSocket socket = new UdpSocket(address.addressFamily);
			socket.setOption(SocketOptionLevel.SOCKET, SocketOption.REUSEADDR, true);
			socket.setOption(SocketOptionLevel.SOCKET, SocketOption.SNDTIMEO, dur!"msecs"(send_timeout));
			socket.setOption(SocketOptionLevel.SOCKET, SocketOption.RCVTIMEO, dur!"msecs"(recv_timeout));
			socket.sendTo(1 ~ new ubyte[8] ~ magic ~ new ubyte[8], address); // server may check the raknet's magic number
			auto timer = StopWatch(AutoStart.yes);
			ubyte[] buffer = new ubyte[512];
			ptrdiff_t r = socket.receiveFrom(buffer, address);
			if(r > 35) { // id (1), ping id (8), server id (8), magic (16), string length (2)
				// MCPE;server name;protocol;version;online;max;server_id;world_name;gametype;
				string res = cast(string)buffer[35..r];
				if(raw) {
					json["pocket"] = res;
				} else {
					string[] query = res.split(";");
					@property string next() {
						string ret = query[0];
						query = query[1..$];
						while(query.length && ret[$-1] == '\\') {
							ret ~= ";" ~ query[0];
							query = query[1..$];
						}
						return ret;
					}
					if(next == "MCPE") {
						JSONValue[string] pocket;
						pocket["motd"] = next;
						pocket["ip"] = ip;
						pocket["port"] = p;
						pocket["protocol"] = to!uint(next);
						pocket["version"] = next;
						pocket["online"] = to!uint(next);
						pocket["max"] = to!uint(next);
						if(query.length) pocket["server_id"] = to!long(next);
						if(query.length) pocket["world"] = next;
						if(query.length) pocket["gametype"] = next;
						pocket["ping"] = timer.peek.msecs;
						json["pocket"] = pocket;
					}
				}
			}
			socket.close();
		} catch(Throwable) {}
	}

	write(JSONValue(json).toString());

}

uint readVarint(ref ubyte[] buffer) {
	uint value = 0;
	uint shift = 0;
	ubyte next = 0x80;
	while(buffer.length && (next & 0x80)) {
		next = buffer[0];
		buffer = buffer[1..$];
		value |= (next & 0x7F) << shift;
		shift += 7;
	}
	return value;
}
