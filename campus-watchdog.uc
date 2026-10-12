#!/usr/bin/ucode
// =============================================================================
// 校园网自动认证看门狗（锐捷 RG-SAM+ ePortal）
//
// 干什么
//   常驻后台，发现掉认证就自动重新登录；学校夜间断网时关掉 5G Wi-Fi（让手机
//   自动回落到流量），早上 06:00:01 准点重登并恢复 5G。
//   断网期间它只是等，不做任何绕过断网的事。
//
// 怎么判断网络状态（在线时每 3 秒一拍）
//   1. ping 一个公网节点，通了就算在线。最便宜，绝大多数时候到此为止。
//   2. ping 不通时，或者每隔约 1 分钟，改用 HTTP 204 探针做“应用层确认”：
//        · 回 204 空响应  → 真的在线
//        · 回门户跳转页    → 掉认证了，立刻登录
//        · 都没结论        → 再用副节点 + 全节点池 ping 做冗余确认
//   为什么不只靠 ping：校园网在未认证时可能放行 ICMP，ping 通不代表能上网。
//   为什么 ping 不通后先问 HTTP 而不是先问副节点：门户跳转页是“掉认证”的直接
//   证据，拿到它就不需要别的节点印证；冗余 ping 只在 HTTP 没结论时才有用。
//
// 夜间逻辑
//   · 只有认证服务器明确回复“不在认证时段内”才进入整夜休眠，不靠时间去猜。
//     （靠时间猜的话，夜里一次几秒的抖动就会被当成断网，白关一晚上 5G。）
//   · 休眠期间不发任何认证请求，只每 5 分钟做一次 HTTP 探测；网络提前恢复就提前醒。
//   · 时间窗口 00:00–06:00 只影响一件事：上游彻底不通时，重试间隔放宽到 5 分钟。
//   · 你的学校断网时段不是 0 点到 6 点的话，改下面的 NIGHT_START_MS 和 WAKE_MS。
//
// 关于时钟
//   多数家用路由器没有硬件时钟，开机时的系统时间是假的（取 /etc 下最新文件的修改时间），
//   要等联网后 NTP 对过表才准。所以凡是依赖“现在几点”的判断，都先看 clock_synced()：
//   没对过表就不信夜间窗口，夜间休眠也不按时钟算唤醒时间，改为每 10 分钟问一次认证服务器。
//
// 相关文件
//   /etc/config/campus_network     账号、密码、门户地址、总开关
//   /etc/init.d/campus-watchdog    服务脚本
//   /tmp/wifi5g_dormant            “5G 是被本脚本关掉的”标记，内容是被关掉的射频名；
//                                  路由器重启后自动消失
//   /var/state/dnsmasqsec          系统自带的“NTP 已对过表”标记（只读，不是本脚本写的）
//
// 日常维护
//   改完本文件：service campus-watchdog restart
//   看日志：    logread -e campus-watchdog
// =============================================================================

'use strict';

import * as fs from 'fs';
import * as uci from 'uci';
import * as ubus from 'ubus';
import * as log from 'log';


// -----------------------------------------------------------------------------
// 可调参数
// -----------------------------------------------------------------------------

const TICK_MS = 3000;              // 主循环节拍：在线时每 3 秒 ping 一次
const HTTP_RECHECK_TICKS = 20;     // ping 正常时，每 20 拍（约 1 分钟）做一次 HTTP 确认

const PING_TIMEOUT_S = 1;          // BusyBox 的 ping 只接受整数秒
const HTTP_TIMEOUT_S = 2;          // 探针请求超时
const LOGIN_TIMEOUT_S = 5;         // 登录请求超时

// 各种失败之后等多久再试。
// 原则：凡是会打到认证服务器的重试都要克制，不给它添负担。
const RETRY_FAST_MS = 30 * 1000;           // 普通失败，刚开始
const RETRY_SLOW_MS = 2 * 60 * 1000;       // 普通失败，持续不好之后；以及欠费
const RETRY_BADPASS_MS = 5 * 60 * 1000;    // 密码错误：重试太勤会锁号
const RETRY_NIGHT_MS = 5 * 60 * 1000;      // 夜间上游不通
const RETRY_UNSYNCED_MS = 10 * 60 * 1000;  // 夜间断网但时钟没对过表：隔这么久问一次认证服务器
const FAST_LOGIN_RETRIES = 3;      // 登录失败的前 3 次用快间隔，之后转慢间隔
const FAST_DOWN_RETRIES = 20;      // 上游不通的前 20 次按正常节拍重试（覆盖开机、插拔网线）

// 时间一律换算成“北京时间当天的第几毫秒”再比较，见 day_ms()。
const TZ_OFFSET_MS = 8 * 3600 * 1000;
const DAY_MS = 24 * 3600 * 1000;
const NIGHT_START_MS = 0;                    // 夜间窗口起点 00:00:00
const WAKE_MS = (6 * 3600 + 1) * 1000;       // 夜间窗口终点，也是晨间唤醒时刻 06:00:01
const NOON_MS = 12 * 3600 * 1000;            // 过了中午再遇到“不在认证时段”，就睡到次日早上
const NIGHT_PROBE_MS = 5 * 60 * 1000;        // 休眠期间多久探测一次网络是否提前恢复

const DORMANT_FLAG = "/tmp/wifi5g_dormant";

// OpenWrt 自带的 /etc/hotplug.d/ntp/25-dnsmasqsec 会在开机后第一次 NTP 对表成功时
// 创建这个文件。它在内存盘上，重启即消失，正好用来判断“系统时间现在可不可信”。
const CLOCK_SYNCED_FLAG = "/var/state/dnsmasqsec";

// ping 节点池：每行是 [主节点, 副节点]，两者属于不同厂商，避免一家抽风就误判。
// 主循环每拍轮换一行，不会长期盯着同一个 IP 打。
const PING_PAIRS = [
    [ "223.5.5.5",    "119.29.29.29" ],      // 阿里      + 腾讯
    [ "180.76.76.76", "114.114.115.115" ],   // 百度      + 114
    [ "180.184.1.1",  "101.198.198.198" ],   // 字节火山  + 电信
    [ "101.6.6.6",    "116.116.116.116" ],   // 清华 TUNA + 联通
    [ "223.6.6.6",    "182.254.116.116" ],   // 阿里      + 腾讯
    [ "1.2.4.8",      "1.12.12.12" ],        // CNNIC     + 腾讯云
    [ "180.184.2.2",  "120.196.165.7" ],     // 字节火山  + 移动
    [ "101.226.4.6",  "210.2.4.8" ],         // DNSPod    + CNNIC
];

// HTTP 探针，按响应速度排序。
// 前三个是手机厂商的联网检测地址：正常联网时返回 204、正文为空。
// 最后一个是纯 IP 地址，在线时得不出结论，只用于 DNS 失灵时仍能撞上门户跳转。
const HTTP_PROBES = [
    "http://connectivitycheck.platform.hicloud.com/generate_204",   // 华为
    "http://wifi.vivo.com.cn/generate_204",                         // vivo
    "http://connect.rom.miui.com/generate_204",                     // 小米
    "http://223.5.5.5/",
];


// -----------------------------------------------------------------------------
// 基础工具
// -----------------------------------------------------------------------------

let cfg = null;    // 由 load_config() 填充，登录时使用

// 写系统日志。固定用 "%s" 当格式串，这样 msg 里出现 % 也只会被当成普通文字。
// （旧版是把消息拼进 `logger '...'` 交给 shell 执行，服务器返回的内容里只要带
//  一个单引号就能注入命令；走 syslog 接口不经过 shell，没有这个问题。）
function say(msg) {
    log.syslog(log.LOG_NOTICE, "%s", msg);
}

// 当前时刻，Unix 毫秒
function now_ms() {
    let c = clock();
    return c[0] * 1000 + int(c[1] / 1000000);
}

// 北京时间当天的第几毫秒（0 ~ 86399999）。
// 直接做算术而不调用 localtime()：后者每次都会重新打开 /etc/TZ 读时区，慢几十倍。
// 中国没有夏令时，固定加 8 小时即可。
function day_ms() {
    return (now_ms() + TZ_OFFSET_MS) % DAY_MS;
}

// 开机后是否已经通过 NTP 对过表。没对过表时系统时间是假的，不能用来做判断。
function clock_synced() {
    return fs.stat(CLOCK_SYNCED_FLAG) != null;
}

// 现在是否处于夜间窗口 00:00–06:00。时钟不可信时一律答“否”。
function is_night() {
    let t = day_ms();
    return clock_synced() && t >= NIGHT_START_MS && t < WAKE_MS;
}

// 距离下一次晨间唤醒（06:00:01）还有多少毫秒。
// 06:00:01 ~ 12:00 之间返回 0，表示“现在已经是早上，不需要再等”。
// 只在 clock_synced() 为真时才有意义。
function ms_until_wake() {
    let t = day_ms();
    if (t >= WAKE_MS && t < NOON_MS)
        return 0;
    return (t < WAKE_MS) ? WAKE_MS - t : DAY_MS - t + WAKE_MS;
}

// 单次 URL 编码：除字母、数字和 - _ . ~ 以外的字节一律转成 %XX
function enc(s) {
    return replace(s, /[^A-Za-z0-9_.~-]/g, (c) => sprintf("%%%02X", ord(c)));
}

// 锐捷门户要求参数做两遍 URL 编码（它的后端会解码两次）
function enc2(s) {
    return enc(enc(s));
}

// 把服务器返回的内容整理成适合写进日志的一行：去掉换行等控制字符，限制长度
function brief(s) {
    return length(s) ? substr(replace(s, /[[:cntrl:]]+/g, " "), 0, 200) : "（空响应）";
}

// 在 /etc/config/wireless 里找 5G 射频的名字（一般是 radio0 或 radio1），找不到返回 null。
// 新版 OpenWrt 用 band '5g' 标记频段，老配置用 hwmode '11a'。
function find_5g_radio(c) {
    let name = null;
    c.foreach("wireless", "wifi-device", (s) => {
        if (name == null && (s.band == "5g" || s.hwmode == "11a"))
            name = s[".name"];
    });
    return name;
}

// 读取 /etc/config/campus_network。缺关键项时写日志并退出。
function load_config() {
    let c = uci.cursor();
    let username = c.get("campus_network", "settings", "username");
    let password = c.get("campus_network", "settings", "password");
    let portal = c.get("campus_network", "settings", "portal_server");   // 可以不填，见 portal_redirect()

    if (!username || !password) {
        say("配置 /etc/config/campus_network 缺少 username 或 password，退出");
        exit(1);
    }
    // 门户地址会被拼进 shell 命令，只允许主机名/IP 里会出现的字符
    if (portal != null && !match(portal, /^[A-Za-z0-9.:-]+$/)) {
        say("配置里的 portal_server 含有非法字符，退出");
        exit(1);
    }

    // 夜间要关哪个射频：night_wifi_off 为 0 表示不关；radio_5g 不填就自动找
    let radio = null;
    if (c.get("campus_network", "settings", "night_wifi_off") != "0") {
        radio = c.get("campus_network", "settings", "radio_5g") ?? find_5g_radio(c);
        if (radio != null && !match(radio, /^[A-Za-z0-9_-]+$/)) {
            say("配置里的 radio_5g 含有非法字符，退出");
            exit(1);
        }
        if (radio == null)
            say("没有找到 5G 射频，夜间断网时只休眠、不关 Wi-Fi");
    }

    // 账号密码在运行期间不变，启动时编码一次，之后每次登录直接用
    return { portal, radio, user_enc: enc2(username), pass_enc: enc2(password) };
}


// -----------------------------------------------------------------------------
// 探测
// -----------------------------------------------------------------------------

// ping 一次，通则返回 true。
// 用数组形式调用 system()，直接执行 ping，不经过 /bin/sh，每次省一个进程。
// 它的输出不需要重定向：服务脚本没有接管 stdout，procd 会把它接到 /dev/null。
function ping(ip) {
    return system([ "ping", "-c", "1", "-W", "" + PING_TIMEOUT_S, "-q", ip ]) == 0;
}

// 并发 ping 节点池里的全部 16 个节点，只要有一个通就返回 true。
// 每个 ping 成功就往管道里写一行 ok，grep -q 读到第一行就算成功；
// 全部不通时大约等 1 秒（ping 的超时）后返回 false。
function pool_alive() {
    let ips = [];
    for (let pair in PING_PAIRS)
        push(ips, pair[0], pair[1]);

    let cmd = sprintf("{ for ip in %s; do (ping -c 1 -W %d -q $ip >/dev/null && echo ok) & done; wait; } 2>/dev/null | grep -q ok",
                      join(" ", ips), PING_TIMEOUT_S);
    return system(cmd) == 0;
}

// 发一个 HTTP GET。返回 { ok: 请求是否成功, body: 正文 }。
// 这里用 popen 是因为要读回正文；url 里的每一段要么是本文件写死的常量，
// 要么经过 enc2() 编码，不会含有单引号。
//
// --no-check-certificate 不是为了跳过安全检查：这里所有地址都是 http://，本来就不涉及
// 证书。不加它的话 wget 每次启动都会先加载整套 CA 证书，单次白烧约 80 ms CPU
// （实测 94 ms → 15 ms，请求耗时也从约 115 ms 降到约 40 ms）。
// 如果以后要在这里请求 https:// 地址，必须去掉这个参数。
function http_get(url, timeout_s) {
    let p = fs.popen(sprintf("wget -q -O - -T %d --no-check-certificate '%s' 2>/dev/null", timeout_s, url), "r");
    if (!p)
        return { ok: false, body: "" };

    let body = p.read("all") ?? "";
    return { ok: p.close() == 0, body };
}

// 解析门户跳转页，返回 { host, qs }；不是跳转页则返回 null。
//   qs    登录要用的 queryString
//   host  门户的地址（跳转链接里没写全时为 null）
// 跳转页长这样：<script>top.self.location.href='http://门户/eportal/index.jsp?wlanuserip=...'</script>
function portal_redirect(html) {
    let m = match(html, /https?:\/\/([A-Za-z0-9.:-]+)\/eportal\/index\.jsp\?([^'"]+)/);
    if (m)
        return { host: m[1], qs: m[2] };

    m = match(html, /index\.jsp\?([^'"]+)/);
    return m ? { host: null, qs: m[1] } : null;
}

// HTTP 应用层探测。返回三种结论之一：
//   { state: "portal", qs, host }   被门户劫持（掉认证了），qs 和 host 见 portal_redirect()
//   { state: "online" }             拿到了 204 空响应，确实能上网
//   { state: "unknown" }      所有探针都没得出结论（超时、DNS 失败等）
function http_probe() {
    for (let url in HTTP_PROBES) {
        let r = http_get(url, HTTP_TIMEOUT_S);

        let redir = portal_redirect(r.body);
        if (redir)
            return { state: "portal", qs: redir.qs, host: redir.host };
        if (r.ok && r.body == "")
            return { state: "online" };
    }
    return { state: "unknown" };
}

// 综合判断当前网络状态。返回：
//   { state: "online" }             在线
//   { state: "portal", qs, host }   掉认证了，可以登录
//   { state: "down" }         上游不通，也没有门户可登
//
// st.trust_ping 的含义：最近一次“确凿的在线证据”（204 或登录成功）之后，才相信 ping。
// 刚启动、刚睡醒、刚见过门户页的时候它是 false，此时必须由 HTTP 说了算，
// 否则“未认证但 ICMP 被放行”会被误判成在线。
function diagnose(st) {
    let pair = PING_PAIRS[st.tick % length(PING_PAIRS)];
    let http_due = (st.tick % HTTP_RECHECK_TICKS == 0);
    st.tick++;

    // 快速路径：ping 可信、通了、又没轮到 HTTP 复核
    let primary_ok = st.trust_ping && ping(pair[0]);
    if (primary_ok && !http_due)
        return { state: "online" };

    let probe = http_probe();
    if (probe.state != "unknown")
        return probe;

    // HTTP 没结论。此时如果 ping 可信，就用冗余 ping 来区分“探针抽风”和“真断了”：
    // 主节点 → 另一家厂商的副节点 → 全部 16 个节点并发。
    if (st.trust_ping && (primary_ok || ping(pair[1]) || pool_alive()))
        return { state: "online" };

    return { state: "down" };
}


// -----------------------------------------------------------------------------
// 登录
// -----------------------------------------------------------------------------

// 向门户发起登录，返回服务器的原始响应（JSON 文本；请求失败时为空串）
function do_login(host, qs) {
    let url = "http://" + host + "/eportal/InterFace.do?method=login" +
              "&userId=" + cfg.user_enc +
              "&password=" + cfg.pass_enc +
              "&service=" +
              "&queryString=" + enc2(qs) +
              "&operatorPwd=" +
              "&operatorUserId=" +
              "&validcode=" +
              "&passwordEncrypt=false";

    return http_get(url, LOGIN_TIMEOUT_S).body;
}

// resp 里是否含有 words 中的任意一个词
function has_any(resp, words) {
    for (let w in words)
        if (index(resp, w) >= 0)
            return true;
    return false;
}

// 把登录响应归类：
//   "ok"       登录成功
//   "night"    不在认证时段内（学校夜间断网）
//   "badpass"  密码错误 / 用户不存在
//   "arrears"  欠费 / 余额不足 / 停机
//   "already"  服务器说账号已在线
//   "other"    其他失败，含空响应
function classify(resp) {
    if (match(resp, /"result"\s*:\s*"success"/))            return "ok";
    if (has_any(resp, [ "不在认证时段内" ]))                 return "night";
    if (has_any(resp, [ "密码错误", "用户不存在" ]))         return "badpass";
    if (has_any(resp, [ "余额不足", "欠费", "停机" ]))       return "arrears";
    if (has_any(resp, [ "该账号已登录", "用户已在线" ]))     return "already";
    return "other";
}


// -----------------------------------------------------------------------------
// 5G Wi-Fi 开关
// -----------------------------------------------------------------------------

// 5G 当前是否处于“被本脚本关掉”的状态。
// 用文件而不是变量来记，是为了脚本中途重启后还能知道要把 5G 恢复回来。
function is_dormant() {
    return fs.stat(DORMANT_FLAG) != null;
}

// 开/关 5G 射频（up 为 true 表示开）。
// 这是运行时操作，不改 /etc/config/wireless，路由器重启后 5G 自然是开的。
// cfg.radio 为 null（没有 5G 射频，或配置里关掉了这个功能）时不碰 Wi-Fi，只维护标记。
function wifi5g(up) {
    if (cfg.radio) {
        let conn = ubus.connect();
        if (conn) {
            conn.call("network.wireless", up ? "up" : "down", { device: cfg.radio });
            conn.disconnect();
        }

        let err = ubus.error();
        if (err) {
            // 没操作成功：保持标记不变，下一次到达同样的状态时会自动重试
            say(sprintf("%s 5G Wi-Fi 失败：%s", up ? "开启" : "关闭", err));
            return;
        }
    }

    // 标记里记下射频名，服务脚本停止时靠它知道该恢复哪个射频
    if (up)
        fs.unlink(DORMANT_FLAG);
    else
        fs.writefile(DORMANT_FLAG, (cfg.radio ?? "") + "\n");

    if (cfg.radio)
        say(up ? "5G Wi-Fi 已开启" : "5G Wi-Fi 已关闭，手机将回落到流量");
}


// -----------------------------------------------------------------------------
// 状态处理
// -----------------------------------------------------------------------------

// 确认在线后的统一收尾。msg 非空时写一条日志。
function mark_online(st, msg) {
    if (msg)
        say(msg);
    st.trust_ping = true;
    st.fails = 0;
    st.last_fault = "";
    if (is_dormant())
        wifi5g(true);
}

// 记一次“没连上”。同一种故障连续出现时只写第一条日志，免得刷屏。
function fault(st, text) {
    st.fails++;
    if (text != st.last_fault) {
        say(text);
        st.last_fault = text;
    }
}

// 夜间休眠：关 5G，一直睡到 06:00:01，或者网络提前恢复。期间不发任何认证请求。
// 例外：时钟没对过表时算不出离 06:00:01 还有多久，只睡 10 分钟就返回，
// 由主循环再问一次认证服务器；它放行了自然就上线，没放行会再进到这里。
function night_sleep() {
    let synced = clock_synced();
    let first = !is_dormant();   // 还没打过标记，说明是今晚第一次进入休眠

    let off = cfg.radio ? "关闭 5G，" : "";
    if (synced)
        say("认证服务器回复“不在认证时段内”，确认夜间断网。" + off + "休眠到 06:00:01");
    else if (first)
        say("认证服务器回复“不在认证时段内”，确认夜间断网。" + off + "路由器开机后还没对过表，无法准点唤醒，改为每 10 分钟询问一次");
    if (first)
        wifi5g(false);

    if (!synced) {
        sleep(RETRY_UNSYNCED_MS);
        return;
    }

    let next_probe = now_ms() + NIGHT_PROBE_MS;
    while (true) {
        let left = ms_until_wake();
        if (left == 0) {
            say("06:00:01 到点，开始晨间认证");
            return;
        }

        // 每 5 分钟看一眼网络是不是提前通了（比如学校临时通宵不断网）。
        // 只认 204，不认 ping：夜里即使 ICMP 被放行，也不能说明可以上网。
        // 离唤醒不足 1 分钟就不探了，免得探测超时把 06:00:01 这个点拖过去。
        if (left > 60 * 1000 && now_ms() >= next_probe) {
            next_probe = now_ms() + NIGHT_PROBE_MS;
            if (http_probe().state == "online") {
                say("夜间网络提前恢复，结束休眠");
                return;
            }
        }

        // 每次最多睡 10 秒就重新看一次表，这样 NTP 校时导致时钟跳变也不会睡过头；
        // 最后一段按剩余毫秒数精确睡，保证准点醒来。
        sleep(min(left, 10 * 1000));
    }
}

// 主循环的一拍：判断网络状态并处理，返回“下一拍之前要等多少毫秒”。
function step(st) {
    let d = diagnose(st);

    // ---- 在线 ----
    if (d.state == "online") {
        mark_online(st, st.fails > 0 ? "网络已恢复" : null);
        return TICK_MS;
    }

    // 只要不是确认在线，就不再相信 ping，直到下一次拿到确凿的在线证据
    st.trust_ping = false;

    // ---- 上游不通：ping 全灭，也撞不到门户，没有可以登录的对象 ----
    // 这里不会打到认证服务器，所以开头可以按正常节拍重试，让开机和插拔网线后尽快恢复；
    // 持续不通就放慢，夜间放得更慢。
    if (d.state == "down") {
        fault(st, "上游不通：ping 全部无响应，也没有门户跳转。等待网络恢复");
        if (st.fails <= FAST_DOWN_RETRIES)
            return TICK_MS;
        return is_night() ? RETRY_NIGHT_MS : RETRY_FAST_MS;
    }

    // ---- 被门户劫持：登录 ----
    // 门户地址以配置为准；配置里没填，就用跳转页里给出的那个
    let host = cfg.portal ?? d.host;
    if (!host) {
        fault(st, "【需要处理】跳转页里没有门户地址，请在 /etc/config/campus_network 里填写 portal_server");
        return RETRY_SLOW_MS;
    }
    let resp = do_login(host, d.qs);

    switch (classify(resp)) {
    case "ok":
        mark_online(st, "认证成功，已上线");
        return TICK_MS;

    case "night":
        // 时钟没对过表时 ms_until_wake() 不可信，一律交给 night_sleep() 处理
        if (!clock_synced() || ms_until_wake() > 0) {
            night_sleep();
            return 0;   // 睡醒后立刻进入下一拍
        }
        // 时钟可信、已经过了 06:00:01，学校还说不在时段：多半是两边时钟差了几秒，按普通失败重试
        fault(st, "已过 06:00，认证服务器仍回复“不在认证时段内”，稍后重试");
        break;

    case "badpass":
        fault(st, "【需要处理】认证服务器回复密码错误或用户不存在。请检查 /etc/config/campus_network，每 5 分钟重试一次");
        return RETRY_BADPASS_MS;

    case "arrears":
        fault(st, "认证服务器回复欠费/余额不足/停机，每 2 分钟重试一次");
        return RETRY_SLOW_MS;

    case "already":
        fault(st, "认证服务器说账号已在线，但仍被门户拦截，每 30 秒重试一次");
        return RETRY_FAST_MS;

    default:
        fault(st, "登录未成功，服务器回复：" + brief(resp));
    }

    // 普通失败：前几次快一点，之后放慢
    return (st.fails <= FAST_LOGIN_RETRIES) ? RETRY_FAST_MS : RETRY_SLOW_MS;
}

function main() {
    log.openlog("campus-watchdog", 0, log.LOG_USER);
    cfg = load_config();
    say("看门狗已启动");

    let st = {
        tick: 0,             // 主循环拍数，用来轮换 ping 节点和安排 HTTP 复核
        trust_ping: false,   // 是否相信 ping 的结果，见 diagnose() 的说明
        fails: 0,            // 连续多少拍没连上（登录失败和上游不通都算）
        last_fault: "",      // 上一条故障日志，用来去重
    };

    while (true) {
        let wait_ms;
        // 任何意外都只影响当前这一拍：记日志、歇 2 分钟再继续，进程本身不退出。
        try {
            wait_ms = step(st);
        } catch (e) {
            say("内部异常，2 分钟后继续：" + e);
            wait_ms = RETRY_SLOW_MS;
        }
        sleep(wait_ms);
    }
}

main();
