package main

import (
	"crypto/ed25519"
	"encoding/hex"
	"errors"
	"fmt"
	"net"
	"net/url"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

// Public Yggdrasil peers, refreshed from https://publicpeers.neilalexander.dev/
// on 2026-09-30. Only peers that were online at that moment are listed;
// stable = online for a week or more. All transports that yggdrasil-go
// v0.5.12 can dial are kept (tls, tcp, quic, ws, wss).
//
// This list is only the emergency starting point. The app is meant to
// learn bridges from other users.

type publicPeer struct {
	uri     string
	country string
	stable  bool
}

var publicPeerPool = []publicPeer{
	{"tcp://37.186.113.100:1514", "Armenia", true},
	{"tls://37.186.113.100:1515", "Armenia", true},
	{"quic://37.186.113.100:1515", "Armenia", false},
	{"ws://37.186.113.100:1516", "Armenia", true},
	{"wss://ygg-evn-1.wgos.org:443", "Armenia", true},
	{"tls://syd.joel.net.au:8443", "Australia", false},
	{"tls://sirsegv.moe:7676", "Australia", true},
	{"tls://yg-syd.magicum.net:23700", "Australia", true},
	{"tcp://yg-syd.magicum.net:23701", "Australia", true},
	{"tcp://yg-mel.magicum.net:23801", "Australia", true},
	{"tcp://ygg7.mk16.de:1337?key=000000086278b5f3ba1eb63acb5b7f6e406f04ce83990dee9c07f49011e375ae", "Austria", true},
	{"tls://ygg7.mk16.de:1338?key=000000086278b5f3ba1eb63acb5b7f6e406f04ce83990dee9c07f49011e375ae", "Austria", true},
	{"ws://ygg7.mk16.de:1340?key=000000086278b5f3ba1eb63acb5b7f6e406f04ce83990dee9c07f49011e375ae", "Austria", true},
	{"tls://109.176.250.101:65534", "Austria", true},
	{"tls://[2a02:1b8:10:147::1:1ea]:65534", "Austria", true},
	{"quic://ip6.casa2.mywire.org:44443?key=000000003cb1cc50e05147fc548f6d1f78e7ffcdc67b456f9bb0db6f0a5e4723", "Brazil", false},
	{"quic://Yggdrasil.UnderEu.Net:37003", "Brazil", false},
	{"tcp://ygg3.mk16.de:1337?key=000003acdaf2a60e8de2f63c3e63b7e911d02380934f09ee5c83acb758f470c1", "Canada", true},
	{"tls://ygg3.mk16.de:1338?key=000003acdaf2a60e8de2f63c3e63b7e911d02380934f09ee5c83acb758f470c1", "Canada", true},
	{"quic://ygg3.mk16.de:1339?key=000003acdaf2a60e8de2f63c3e63b7e911d02380934f09ee5c83acb758f470c1", "Canada", false},
	{"ws://ygg3.mk16.de:1340?key=000003acdaf2a60e8de2f63c3e63b7e911d02380934f09ee5c83acb758f470c1", "Canada", true},
	{"quic://scarlet.mboa.dev:3443", "Canada", false},
	{"tcp://ygg-1.okade.pro:20000", "Chile", true},
	{"tcp://ygg.nadeko.net:44441", "Chile", true},
	{"tls://ygg.nadeko.net:44442", "Chile", true},
	{"tls://[2a03:3b40:fe:ab::1]:993?key=0009e16b9e3afe7b13c3612560410434d3dfc70c8a8a0a63e51e0470cb8124f6", "Czechia", true},
	{"tls://37.205.14.171:993?key=0009e16b9e3afe7b13c3612560410434d3dfc70c8a8a0a63e51e0470cb8124f6", "Czechia", true},
	{"tcp://ygg-hel-1.wgos.org:45170", "Finland", true},
	{"quic://ygg-hel-1.wgos.org:45171", "Finland", false},
	{"tls://ygg-hel-1.wgos.org:45171", "Finland", true},
	{"ws://ygg-hel-1.wgos.org:45172", "Finland", true},
	{"tls://[2a01:4f9:2b:2d8f::2]:1337", "Finland", true},
	{"tls://95.217.35.92:1337", "Finland", true},
	{"wss://ygg.fi.mvault.ru.net:443", "Finland", false},
	{"tcp://[2001:470:1f13:e56::64]:39565", "France", true},
	{"tls://[2001:470:1f13:e56::64]:39575", "France", true},
	{"tcp://62.210.85.80:39565", "France", true},
	{"tls://62.210.85.80:39575", "France", true},
	{"tcp://s2.i2pd.xyz:39565", "France", true},
	{"tls://s2.i2pd.xyz:39575", "France", true},
	{"tcp://51.15.204.214:12345", "France", true},
	{"tls://51.15.204.214:54321", "France", true},
	{"tcp://yggpeer.tilde.green:53299", "France", true},
	{"tls://yggpeer.tilde.green:59454", "France", true},
	{"tls://ygg.jholden.org:1555", "France", true},
	{"quic://ip4.fvm.mywire.org:443?key=000000000143db657d1d6f80b5066dd109a4cb31f7dc6cb5d56050fffb014217", "Germany", false},
	{"tcp://ip4.fvm.mywire.org:8080?key=000000000143db657d1d6f80b5066dd109a4cb31f7dc6cb5d56050fffb014217", "Germany", false},
	{"quic://ip6.fvm.mywire.org:443?key=000000000143db657d1d6f80b5066dd109a4cb31f7dc6cb5d56050fffb014217", "Germany", false},
	{"tcp://ip6.fvm.mywire.org:8080?key=000000000143db657d1d6f80b5066dd109a4cb31f7dc6cb5d56050fffb014217", "Germany", false},
	{"tcp://ygg1.mk16.de:1337?key=0000000087ee9949eeab56bd430ee8f324cad55abf3993ed9b9be63ce693e18a", "Germany", true},
	{"tls://ygg1.mk16.de:1338?key=0000000087ee9949eeab56bd430ee8f324cad55abf3993ed9b9be63ce693e18a", "Germany", true},
	{"quic://ygg1.mk16.de:1339?key=0000000087ee9949eeab56bd430ee8f324cad55abf3993ed9b9be63ce693e18a", "Germany", false},
	{"ws://ygg1.mk16.de:1340?key=0000000087ee9949eeab56bd430ee8f324cad55abf3993ed9b9be63ce693e18a", "Germany", true},
	{"tcp://yggdrasil.su:62486", "Germany", true},
	{"tls://yggdrasil.su:62586", "Germany", true},
	{"tcp://87.251.77.39:65535", "Germany", true},
	{"quic://87.251.77.39:65535", "Germany", false},
	{"tcp://ygg2.mk16.de:1337?key=000000d80a2d7b3126ea65c8c08fc751088c491a5cdd47eff11c86fa1e4644ae", "Germany", true},
	{"tls://ygg2.mk16.de:1338?key=000000d80a2d7b3126ea65c8c08fc751088c491a5cdd47eff11c86fa1e4644ae", "Germany", true},
	{"quic://ygg2.mk16.de:1339?key=000000d80a2d7b3126ea65c8c08fc751088c491a5cdd47eff11c86fa1e4644ae", "Germany", true},
	{"ws://ygg2.mk16.de:1340?key=000000d80a2d7b3126ea65c8c08fc751088c491a5cdd47eff11c86fa1e4644ae", "Germany", true},
	{"quic://des.8px.sk:4321", "Germany", false},
	{"tls://des.8px.sk:4321", "Germany", false},
	{"tls://91.98.161.68:9001?key=0e638944bfd6b277fa5e0dddbeb4444778eea8bece63a9862c661797022a8f05", "Germany", true},
	{"tcp://ygg.mkg20001.io:80", "Germany", true},
	{"tls://ygg.mkg20001.io:443", "Germany", true},
	{"tls://reticulum.me:12393?key=a3d411280dfc350a4484aa3da5feb0407518c5820cbb011d5620347769b26665", "Germany", true},
	{"tls://yggdrasil.neilalexander.dev:64648?key=ecbbcb3298e7d3b4196103333c3e839cfe47a6ca47602b94a6d596683f6bb358", "Germany", true},
	{"tcp://bode.theender.net:42069", "Germany", true},
	{"tls://bode.theender.net:42169?key=f91b909f43829f8b20732b3bcf80cbc4bb078dd47b41638379a078e35984c9a4", "Germany", true},
	{"tcp://ygg5.mk16.de:1337?key=0000009611ae5391dc0aceea9f3fa6a0dc1279f4306059339e84bfb8b74d2f9b", "Hong Kong", true},
	{"tls://ygg5.mk16.de:1338?key=0000009611ae5391dc0aceea9f3fa6a0dc1279f4306059339e84bfb8b74d2f9b", "Hong Kong", true},
	{"quic://ygg5.mk16.de:1339?key=0000009611ae5391dc0aceea9f3fa6a0dc1279f4306059339e84bfb8b74d2f9b", "Hong Kong", false},
	{"ws://ygg5.mk16.de:1340?key=0000009611ae5391dc0aceea9f3fa6a0dc1279f4306059339e84bfb8b74d2f9b", "Hong Kong", true},
	{"ws://ygg1.grin.hu:42443", "Hungary", true},
	{"tls://ygg1.grin.hu:42444", "Hungary", true},
	{"tls://ins.8px.sk:4321", "India", true},
	{"quic://ins.8px.sk:4321", "India", false},
	{"tls://supanadit.com:15021", "Indonesia", false},
	{"quic://supanadit.com:15022", "Indonesia", false},
	{"tls://133.18.201.69:54232", "Japan", true},
	{"tls://153.120.42.137:54232", "Japan", true},
	{"tls://yg-tyo.magicum.net:32333", "Japan", true},
	{"tcp://yg-tyo.magicum.net:32334", "Japan", true},
	{"tcp://vpn.itrus.su:7991", "Netherlands", false},
	{"tls://vpn.itrus.su:7992", "Netherlands", true},
	{"ws://vpn.itrus.su:7994", "Netherlands", true},
	{"tcp://146.103.111.53:65535", "Netherlands", true},
	{"quic://146.103.111.53:65535", "Netherlands", false},
	{"tcp://[2a14:1e00:3:15c::]:65535", "Netherlands", true},
	{"quic://[2a14:1e00:3:15c::]:65535", "Netherlands", false},
	{"tcp://109.107.177.127:65535", "Netherlands", true},
	{"quic://109.107.177.127:65535", "Netherlands", true},
	{"quic://[2a0d:8480:3:234c::]:65535", "Netherlands", true},
	{"tcp://[2a0d:8480:3:234c::]:65535", "Netherlands", true},
	{"quic://[2a14:1e00:1:ecd::]:65535", "Netherlands", false},
	{"tcp://[2a14:1e00:1:ecd::]:65535", "Netherlands", true},
	{"tcp://5.35.70.181:65535", "Netherlands", true},
	{"quic://5.35.70.181:65535", "Netherlands", false},
	{"quic://[2a14:1e00:1:f3c::]:65535", "Netherlands", false},
	{"tcp://[2a14:1e00:1:f3c::]:65535", "Netherlands", true},
	{"tcp://89.110.116.167:65535", "Netherlands", true},
	{"quic://89.110.116.167:65535", "Netherlands", false},
	{"quic://212.34.131.160:65535", "Netherlands", false},
	{"tcp://212.34.131.160:65535", "Netherlands", true},
	{"tcp://[2a14:1e00:1:bae::]:65535", "Netherlands", true},
	{"quic://[2a14:1e00:1:bae::]:65535", "Netherlands", false},
	{"quic://146.103.107.222:65535", "Netherlands", false},
	{"tcp://146.103.107.222:65535", "Netherlands", true},
	{"tcp://[2a14:1e00:3:2b2::]:65535", "Netherlands", true},
	{"quic://[2a14:1e00:3:2b2::]:65535", "Netherlands", false},
	{"tls://nl1.route172.de:443?key=000000002643ae27bad63e2a81f1d30554ce9ea634f5990062a9e079e23593cd", "Netherlands", true},
	{"tcp://nl1.route172.de:65535?key=000000002643ae27bad63e2a81f1d30554ce9ea634f5990062a9e079e23593cd", "Netherlands", false},
	{"quic://nl1.route172.de:65535?key=000000002643ae27bad63e2a81f1d30554ce9ea634f5990062a9e079e23593cd", "Netherlands", true},
	{"tcp://[2a0d:8480:1:209e::]:65535", "Netherlands", true},
	{"quic://[2a0d:8480:1:209e::]:65535", "Netherlands", false},
	{"tcp://88.210.10.78:65535", "Netherlands", true},
	{"quic://88.210.10.78:65535", "Netherlands", false},
	{"tls://5.252.118.13:443", "Netherlands", true},
	{"tcp://5.252.118.13:65535", "Netherlands", true},
	{"quic://5.252.118.13:65535", "Netherlands", false},
	{"tcp://ygg.bruijn.nu:65535", "Netherlands", true},
	{"tcp://cirno.nadeko.net:44441", "Netherlands", false},
	{"tls://cirno.nadeko.net:44442", "Netherlands", false},
	{"tcp://no0.yggdrasil.netralex.com:65533?key=f4b9fe4f9923834b1c20f84e13b14d90ecde443f78613ec54cf484eea6880fea", "Norway", true},
	{"tls://no0.yggdrasil.netralex.com:65534?key=f4b9fe4f9923834b1c20f84e13b14d90ecde443f78613ec54cf484eea6880fea", "Norway", true},
	{"quic://no0.yggdrasil.netralex.com:65535?key=f4b9fe4f9923834b1c20f84e13b14d90ecde443f78613ec54cf484eea6880fea", "Norway", true},
	{"tcp://waw01.yggdrasil.hosted-by.skhron.eu:8883?key=030602cee88a761c68f5f14e1dad430f25238a703b69dc382321a38f833035b0", "Poland", true},
	{"tls://waw01.yggdrasil.hosted-by.skhron.eu:8884?key=030602cee88a761c68f5f14e1dad430f25238a703b69dc382321a38f833035b0", "Poland", true},
	{"quic://waw01.yggdrasil.hosted-by.skhron.eu:8885?key=030602cee88a761c68f5f14e1dad430f25238a703b69dc382321a38f833035b0", "Poland", true},
	{"ws://waw01.yggdrasil.hosted-by.skhron.eu:8886?key=030602cee88a761c68f5f14e1dad430f25238a703b69dc382321a38f833035b0", "Poland", true},
	{"tls://ygg-ro.axxa.dev:18080", "Romania", false},
	{"wss://assets.route172.de:443/api/request/media?key=00000000000da547036a01860a9e3a0476a525415801ec34f4e5b59fd6055b88", "Russia", false},
	{"tls://kursk.cleverfox.org:15015", "Russia", true},
	{"quic://kursk.cleverfox.org:15015", "Russia", false},
	{"ws://kursk.cleverfox.org:15016", "Russia", true},
	{"tls://ygg-msk-1.averyan.ru:8362", "Russia", false},
	{"tcp://ygg-msk-1.averyan.ru:8363", "Russia", false},
	{"quic://ygg-msk-1.averyan.ru:8364", "Russia", true},
	{"tcp://kem.txlyre.website:1337", "Russia", true},
	{"tcp://box.paulll.cc:13337", "Russia", true},
	{"tls://box.paulll.cc:13338", "Russia", true},
	{"tcp://yggno.de:18226", "Russia", false},
	{"tls://yggno.de:18227", "Russia", false},
	{"wss://donotclickthis.link:443/api/v2/socket", "Russia", false},
	{"quic://vix.duckdns.org:36014", "Russia", false},
	{"tls://vix.duckdns.org:36014", "Russia", false},
	{"tcp://u-neroit.ru:7000", "Russia", false},
	{"tls://37.192.232.33:442", "Russia", false},
	{"tcp://37.192.232.33:8080", "Russia", false},
	{"tcp://yg-vvo.magicum.net:29330", "Russia", true},
	{"tls://yg-vvo.magicum.net:29331", "Russia", true},
	{"tcp://itcom.multed.com:7991", "Russia", true},
	{"wss://ygg.mvault.ru.net:443", "Russia", false},
	{"quic://ekb.itrus.su:7993", "Russia", false},
	{"quic://asia.deinfra.org:15015", "Singapore", false},
	{"tls://asia.deinfra.org:15015", "Singapore", false},
	{"tls://yg-sin.magicum.net:23900", "Singapore", true},
	{"tcp://yg-sin.magicum.net:23901", "Singapore", true},
	{"tcp://y.zbin.eu:7743", "Slovakia", false},
	{"quic://ygg-ke.8px.sk:4321", "Slovakia", false},
	{"tls://ygg-ke.8px.sk:4321", "Slovakia", false},
	{"tcp://r1.worcester.yggdrasil.novasredes.network:2000", "South Africa", true},
	{"tls://r1.worcester.yggdrasil.novasredes.network:2001", "South Africa", false},
	{"tcp://r2.worcester.yggdrasil.novasredes.network:2000", "South Africa", true},
	{"tls://r2.worcester.yggdrasil.novasredes.network:2001", "South Africa", false},
	{"tcp://rendezvous.anton.molyboha.me:50421", "Spain", true},
	{"tcp://sto01.yggdrasil.hosted-by.skhron.eu:8883?key=ce8cfa43b8c9e71c1fe31832b39403f23166f2bac12d52c755d9ac68f55da81c", "Sweden", true},
	{"tls://sto01.yggdrasil.hosted-by.skhron.eu:8884?key=ce8cfa43b8c9e71c1fe31832b39403f23166f2bac12d52c755d9ac68f55da81c", "Sweden", true},
	{"quic://sto01.yggdrasil.hosted-by.skhron.eu:8885?key=ce8cfa43b8c9e71c1fe31832b39403f23166f2bac12d52c755d9ac68f55da81c", "Sweden", true},
	{"ws://sto01.yggdrasil.hosted-by.skhron.eu:8886?key=ce8cfa43b8c9e71c1fe31832b39403f23166f2bac12d52c755d9ac68f55da81c", "Sweden", true},
	{"wss://ygg.ch.mvault.ru.net:443", "Switzerland", false},
	{"tls://cowgl.tech:1337", "Taiwan", true},
	{"tls://193.93.119.42:443", "Ukraine", true},
	{"ws://193.93.119.42:850", "Ukraine", true},
	{"quic://193.93.119.42:1443", "Ukraine", true},
	{"tcp://193.93.119.42:14244", "Ukraine", true},
	{"quic://yggdrasil.sunsung.fun:4441", "Ukraine", false},
	{"tcp://yggdrasil.sunsung.fun:4442", "Ukraine", true},
	{"tls://yggdrasil.sunsung.fun:4443", "Ukraine", true},
	{"tls://78.27.153.163:3784", "Ukraine", true},
	{"tls://78.27.153.163:3785", "Ukraine", true},
	{"tcp://78.27.153.163:33165", "Ukraine", true},
	{"tls://78.27.153.163:33166", "Ukraine", true},
	{"tcp://uk-lon1.ygg-public-peers.h.wer.ee:17160", "United Kingdom", false},
	{"tls://uk-lon1.ygg-public-peers.h.wer.ee:17161", "United Kingdom", false},
	{"tls://london.sabretruth.org:18472", "United Kingdom", true},
	{"tcp://london.sabretruth.org:18473", "United Kingdom", true},
	{"tls://ca.us.ygg.informatics.coop:443?key=0000000023fc6ffb62afb79448aefb0943df2e4472cf08bd489f5407378300a2", "United States", true},
	{"quic://ip4.nerdvm.mywire.org:443?key=00000000c61d731961a290d127cd3fc03a4c5f3f35b9083559d4c81d48d65854", "United States", false},
	{"tcp://ip4.nerdvm.mywire.org:8080?key=00000000c61d731961a290d127cd3fc03a4c5f3f35b9083559d4c81d48d65854", "United States", false},
	{"quic://ip6.nerdvm.mywire.org:443?key=00000000c61d731961a290d127cd3fc03a4c5f3f35b9083559d4c81d48d65854", "United States", true},
	{"tcp://ip6.nerdvm.mywire.org:8080?key=00000000c61d731961a290d127cd3fc03a4c5f3f35b9083559d4c81d48d65854", "United States", true},
	{"tcp://ygg8.mk16.de:1337?key=0000000b0683e38d8cb3085cfbf217edf0f0b2de76bb5ac7f02a94cd42a3fed9", "United States", true},
	{"tls://ygg8.mk16.de:1338?key=0000000b0683e38d8cb3085cfbf217edf0f0b2de76bb5ac7f02a94cd42a3fed9", "United States", true},
	{"quic://ygg8.mk16.de:1339?key=0000000b0683e38d8cb3085cfbf217edf0f0b2de76bb5ac7f02a94cd42a3fed9", "United States", true},
	{"ws://ygg8.mk16.de:1340?key=0000000b0683e38d8cb3085cfbf217edf0f0b2de76bb5ac7f02a94cd42a3fed9", "United States", true},
	{"tcp://ygg4.mk16.de:1337?key=000000573433e11f23768b078bcdc10b42712a7b131d6d04b82042ffc0c97df0", "United States", false},
	{"tls://ygg4.mk16.de:1338?key=000000573433e11f23768b078bcdc10b42712a7b131d6d04b82042ffc0c97df0", "United States", false},
	{"quic://ygg4.mk16.de:1339?key=000000573433e11f23768b078bcdc10b42712a7b131d6d04b82042ffc0c97df0", "United States", false},
	{"ws://ygg4.mk16.de:1340?key=000000573433e11f23768b078bcdc10b42712a7b131d6d04b82042ffc0c97df0", "United States", false},
	{"tcp://ygg1.asriyan.me:23672", "United States", true},
	{"quic://23.184.48.86:1443", "United States", false},
	{"tls://23.184.48.86:1443", "United States", true},
	{"quic://mo.us.ygg.triplebit.org:443", "United States", false},
	{"tls://mo.us.ygg.triplebit.org:993", "United States", false},
	{"tcp://mo.us.ygg.triplebit.org:9000", "United States", false},
	{"ws://mo.us.ygg.triplebit.org:9010", "United States", false},
	{"tcp://leo.node.3dt.net:9002", "United States", true},
	{"tls://leo.node.3dt.net:9003", "United States", true},
	{"quic://leo.node.3dt.net:9004", "United States", false},
	{"tcp://ygg-kcmo.incognet.io:8883", "United States", true},
	{"tls://ygg-kcmo.incognet.io:8884", "United States", true},
	{"quic://ygg-kcmo.incognet.io:8885", "United States", false},
	{"ws://ygg-kcmo.incognet.io:8886", "United States", true},
	{"quic://mn.us.ygg.triplebit.org:443", "United States", false},
	{"tls://mn.us.ygg.triplebit.org:993", "United States", true},
	{"tcp://mn.us.ygg.triplebit.org:9000", "United States", false},
	{"ws://mn.us.ygg.triplebit.org:9010", "United States", false},
	{"tcp://longseason.1200bps.xyz:13121", "United States", true},
	{"tls://longseason.1200bps.xyz:13122", "United States", true},
	{"tcp://ygg-pa.incognet.io:8883", "United States", false},
	{"tls://ygg-pa.incognet.io:8884", "United States", false},
	{"quic://ygg-pa.incognet.io:8885", "United States", false},
	{"ws://ygg-pa.incognet.io:8886", "United States", false},
	{"tcp://marisa.nadeko.net:44441", "United States", true},
	{"tls://marisa.nadeko.net:44442", "United States", true},
	{"tcp://ygg-wa.incognet.io:8883", "United States", true},
	{"tls://ygg-wa.incognet.io:8884", "United States", true},
	{"quic://ygg-wa.incognet.io:8885", "United States", true},
	{"ws://ygg-wa.incognet.io:8886", "United States", true},
	{"tls://ygg.mnpnk.com:443", "United States", true},
	{"tls://31.22.111.195:32000", "United States", true},
}

func publicPeerURIs(pool []publicPeer) []string {
	uris := make([]string, 0, len(pool))
	for _, peer := range pool {
		uris = append(uris, peer.uri)
	}
	return uris
}

func peerScheme(uri string) string {
	parsed, err := url.Parse(strings.TrimSpace(uri))
	if err != nil {
		return ""
	}
	return strings.ToLower(parsed.Scheme)
}

func peerHostIsIPv4(uri string) bool {
	parsed, err := url.Parse(strings.TrimSpace(uri))
	if err != nil {
		return false
	}
	ip := net.ParseIP(parsed.Hostname())
	return ip != nil && ip.To4() != nil
}

func peerHostIsIPv6Literal(uri string) bool {
	parsed, err := url.Parse(strings.TrimSpace(uri))
	if err != nil {
		return false
	}
	ip := net.ParseIP(parsed.Hostname())
	return ip != nil && ip.To4() == nil
}

// selectAndroidBootstrapPeers picks stable TLS peers, IPv4 literals first
// (no DNS needed), then port 443, keeping the pool order otherwise.
func selectAndroidBootstrapPeers(pool []publicPeer, count int) []string {
	candidates := make([]string, 0, len(pool))
	for _, peer := range pool {
		if !peer.stable || peerScheme(peer.uri) != "tls" || peerHostIsIPv6Literal(peer.uri) {
			continue
		}
		candidates = append(candidates, peer.uri)
	}
	sort.SliceStable(candidates, func(i, j int) bool {
		ai, aj := peerHostIsIPv4(candidates[i]), peerHostIsIPv4(candidates[j])
		if ai != aj {
			return ai
		}
		return publicPeerScore(candidates[i]) > publicPeerScore(candidates[j])
	})
	if len(candidates) > count {
		candidates = candidates[:count]
	}
	return candidates
}

// phonePeerCandidates is a phone's whole pool in the order it tries the
// peers: its picks first (selectAndroidBootstrapPeers), then every other
// encrypted peer of the pool in reserve — stable before unstable, IPv6
// literals last (many mobile networks have none). The phone dials only a
// few at once (phonePeerCount) and swaps one that stays down for the next
// (peerRotation): with the whole pool behind its picks, a phone whose
// picks went dead (the list is a snapshot) moves on to peers that still
// answer instead of going round the dead ones.
func phonePeerCandidates(pool []publicPeer) []string {
	picks := selectAndroidBootstrapPeers(pool, phonePeerPoolSize)
	taken := make(map[string]bool, len(pool))
	for _, uri := range picks {
		taken[uri] = true
	}
	reserve := make([]publicPeer, 0, len(pool))
	for _, peer := range pool {
		if taken[peer.uri] || !isEncryptedPeerURI(peer.uri) {
			continue
		}
		taken[peer.uri] = true
		reserve = append(reserve, peer)
	}
	rank := func(peer publicPeer) int {
		score := 0
		if peerHostIsIPv6Literal(peer.uri) {
			score += 2
		}
		if !peer.stable {
			score++
		}
		return score
	}
	sort.SliceStable(reserve, func(i, j int) bool {
		return rank(reserve[i]) < rank(reserve[j])
	})
	candidates := append([]string(nil), picks...)
	for _, peer := range reserve {
		candidates = append(candidates, peer.uri)
	}
	return candidates
}

// desktopPublicPeers is what a desktop dials: the first of the user's list
// when they made one, else a spread over as many countries as possible —
// one stable peer per country per round, TLS preferred, encrypted
// transports only, one URI per host (two links to one node only take a
// slot), no IPv6 literals (many homes have no IPv6).
func desktopPublicPeers(count int) []string {
	if uris, ok := firstUserPeers(count); ok {
		return uris
	}
	return builtInDesktopPeers(count)
}

// builtInDesktopPeers is the desktop's spread over the built-in pool.
func builtInDesktopPeers(count int) []string {
	schemeRank := map[string]int{"tls": 0, "quic": 1, "wss": 2}
	byCountry := map[string][]string{}
	countries := make([]string, 0)
	for _, peer := range builtInPublicPeers() {
		if _, ok := schemeRank[peerScheme(peer.uri)]; !ok || !peer.stable || peerHostIsIPv6Literal(peer.uri) {
			continue
		}
		if _, seen := byCountry[peer.country]; !seen {
			countries = append(countries, peer.country)
		}
		byCountry[peer.country] = append(byCountry[peer.country], peer.uri)
	}
	for _, country := range countries {
		list := byCountry[country]
		sort.SliceStable(list, func(i, j int) bool {
			return schemeRank[peerScheme(list[i])] < schemeRank[peerScheme(list[j])]
		})
	}
	selected := make([]string, 0, count)
	hosts := map[string]bool{}
	for round := 0; len(selected) < count; round++ {
		added := false
		for _, country := range countries {
			list := byCountry[country]
			if round >= len(list) {
				continue
			}
			added = true
			host := peerHost(list[round])
			if hosts[host] {
				continue
			}
			hosts[host] = true
			selected = append(selected, list[round])
			if len(selected) >= count {
				break
			}
		}
		if !added {
			break
		}
	}
	return selected
}

func peerHost(uri string) string {
	parsed, err := url.Parse(strings.TrimSpace(uri))
	if err != nil {
		return uri
	}
	return strings.ToLower(parsed.Hostname())
}

// desktopRuntimePeers keeps peers the user or the app added that are not
// public (loopback, LAN) and replaces every public entry with the current
// spread-out selection.
func desktopRuntimePeers(existing []string) []string {
	peers := make([]string, 0, len(existing)+desktopPublicPeerCount)
	seen := map[string]bool{}
	for _, peer := range existing {
		if peer == "" || seen[peer] || !isLocalPeerURI(peer) {
			continue
		}
		seen[peer] = true
		peers = append(peers, peer)
	}
	for _, peer := range desktopPublicPeers(desktopPublicPeerCount) {
		if !seen[peer] {
			seen[peer] = true
			peers = append(peers, peer)
		}
	}
	return peers
}

func isLocalPeerURI(peer string) bool {
	if isLoopbackPeerURI(peer) {
		return true
	}
	parsed, err := url.Parse(strings.TrimSpace(peer))
	if err != nil {
		return false
	}
	ip := net.ParseIP(parsed.Hostname())
	return ip != nil && (ip.IsPrivate() || ip.IsLinkLocalUnicast())
}

// Encrypted transports. tls://, quic:// and wss:// links run TLS 1.3,
// where Go negotiates the hybrid X25519MLKEM768 key exchange by default:
// whoever watches the line (the ISP, a café network) sees neither which
// Yggdrasil keys this node talks to (ironwood headers carry them in clear)
// nor its routing traffic. tcp:// and ws:// carry all of that in clear, so
// the app never picks them on its own; a user may still add one.
var encryptedPeerSchemes = map[string]bool{"tls": true, "quic": true, "wss": true}

func isEncryptedPeerURI(uri string) bool {
	return encryptedPeerSchemes[peerScheme(uri)]
}

// builtInPublicPeers is the pool the app chooses from by itself: every
// listed peer on an encrypted transport.
func builtInPublicPeers() []publicPeer {
	pool := make([]publicPeer, 0, len(publicPeerPool))
	for _, peer := range publicPeerPool {
		if isEncryptedPeerURI(peer.uri) {
			pool = append(pool, peer)
		}
	}
	return pool
}

// The public peers the user chose in the app (YggSetPublicPeersJson), in
// their order; unset: the built-in pool.
var userPublicPeers struct {
	mu   sync.RWMutex
	set  bool
	uris []string
}

func setUserPublicPeers(uris []string, set bool) {
	userPublicPeers.mu.Lock()
	defer userPublicPeers.mu.Unlock()
	userPublicPeers.set = set
	userPublicPeers.uris = append([]string(nil), uris...)
}

func currentUserPublicPeers() ([]string, bool) {
	userPublicPeers.mu.RLock()
	defer userPublicPeers.mu.RUnlock()
	return append([]string(nil), userPublicPeers.uris...), userPublicPeers.set
}

// activePublicPeerPool is what probing, the phone's starting set and the
// desktop's selection come from: the user's list, or the built-in pool.
func activePublicPeerPool() []publicPeer {
	if uris, set := currentUserPublicPeers(); set {
		pool := make([]publicPeer, 0, len(uris))
		for _, uri := range uris {
			pool = append(pool, publicPeer{uri: uri, stable: true})
		}
		return pool
	}
	return builtInPublicPeers()
}

func defaultPublicPeerURIs() []string {
	return publicPeerURIs(activePublicPeerPool())
}

// firstUserPeers is the user's list (when set) cut to count, in the
// user's order: what they chose is dialled as chosen.
func firstUserPeers(count int) ([]string, bool) {
	uris, set := currentUserPublicPeers()
	if !set {
		return nil, false
	}
	if len(uris) > count {
		uris = uris[:count]
	}
	return uris, true
}

// Query options of a peer URI that Yggdrasil 0.5 understands.
var peerURIOptions = map[string]bool{
	"key": true, "priority": true, "password": true, "maxbackoff": true, "sni": true,
}

// validatePeerURI checks a peer URI as Yggdrasil 0.5.14 would dial it, but
// stricter where Yggdrasil is lenient (a short ?key= is padded with zeros
// there, an unknown option ignored), and returns it normalised.
func validatePeerURI(raw string) (string, error) {
	raw = strings.TrimSpace(raw)
	if raw == "" || len(raw) > 512 {
		return "", errors.New("empty or too long")
	}
	parsed, err := url.Parse(raw)
	if err != nil {
		return "", fmt.Errorf("not a URI: %w", err)
	}
	scheme := strings.ToLower(parsed.Scheme)
	switch scheme {
	case "tls", "quic", "tcp", "ws", "wss":
	default:
		return "", fmt.Errorf("unsupported transport %q", parsed.Scheme)
	}
	parsed.Scheme = scheme
	if parsed.Opaque != "" || parsed.User != nil || parsed.Fragment != "" {
		return "", errors.New("unexpected parts")
	}
	host := parsed.Hostname()
	if host == "" {
		return "", errors.New("no host")
	}
	if ip := net.ParseIP(host); ip != nil {
		if ip.IsUnspecified() || ip.IsMulticast() || isYggNodeAddress(ip) || (ip.To4() == nil && ip.To16()[0]&0xfe == 0x02) {
			return "", errors.New("not a dialable address")
		}
	}
	port := parsed.Port()
	if port == "" && (scheme == "tcp" || scheme == "tls" || scheme == "quic") {
		return "", errors.New("no port")
	}
	if port != "" {
		number, err := strconv.Atoi(port)
		if err != nil || number < 1 || number > 65535 {
			return "", errors.New("bad port")
		}
	}
	if scheme != "ws" && scheme != "wss" && parsed.Path != "" && parsed.Path != "/" {
		return "", errors.New("a path only goes with ws:// and wss://")
	}
	query := parsed.Query()
	for name, values := range query {
		if !peerURIOptions[name] {
			return "", fmt.Errorf("unknown option %q", name)
		}
		if name != "key" && len(values) != 1 {
			return "", fmt.Errorf("option %q given twice", name)
		}
	}
	for _, key := range query["key"] {
		decoded, err := hex.DecodeString(key)
		if err != nil || len(decoded) != ed25519.PublicKeySize {
			return "", errors.New("key must be 64 hex digits")
		}
	}
	if value := query.Get("priority"); value != "" {
		if _, err := strconv.ParseUint(value, 10, 8); err != nil {
			return "", errors.New("priority must be 0-255")
		}
	}
	if value := query.Get("password"); len(value) > 64 {
		return "", errors.New("password longer than 64 bytes")
	}
	if value := query.Get("maxbackoff"); value != "" {
		duration, err := time.ParseDuration(value)
		if err != nil || duration < 5*time.Second {
			return "", errors.New("maxbackoff must be a duration of 5s or more")
		}
	}
	if value := query.Get("sni"); value != "" && net.ParseIP(value) != nil {
		return "", errors.New("sni must be a name")
	}
	return parsed.String(), nil
}

// peerPinnedKeys are the ?key= values of a peer URI (lower case hex).
func peerPinnedKeys(uri string) []string {
	parsed, err := url.Parse(uri)
	if err != nil {
		return nil
	}
	keys := make([]string, 0, 1)
	for _, key := range parsed.Query()["key"] {
		keys = append(keys, strings.ToLower(key))
	}
	return keys
}
