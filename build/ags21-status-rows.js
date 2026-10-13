
/* ============================================================================
 *  AGS21 注入段 —— 温度 / CPU 使用率两行，插进「系统」面板
 *  （由 build/build-ags21.sh 自动注入到 feeds/luci 的
 *    luci-mod-status/htdocs/luci-static/resources/view/status/include/10_system.js
 *    里，源文件在本仓库 build/ags21-status-rows.js。别改源码树里的副本。）
 *
 *  ── 为什么要动上游这个文件 ────────────────────────────────────────────
 *  用户的参照物是 ImmortalWrt 首页那句：
 *       温度            CPU: 58.4°C, WiFi: 44.0°C 44.0°C
 *       CPU 使用率（%）  28%
 *  这两行在 ImmortalWrt 里是**「系统」面板内部的字段**，不是独立的 include
 *  面板 —— 面板之间没法互相插行，所以只能改 10_system.js 的 fields 数组。
 *
 *  ── ImmortalWrt 是怎么做的，我们为什么不照抄 ────────────────────────
 *  ImmortalWrt = package/emortal/autocore（提供 /sbin/tempinfo、/sbin/cpuinfo）
 *  + luci-base 里一个 ucode rpcd 插件（暴露 luci.getTempInfo / getCPUUsage）
 *  + 10_system.js 里加两个 rpc.declare。三处缺一不可。
 *  我们用的是**上游 luci**，没有那个 ucode 插件；而这三样是现成的官方数据源
 *  （/proc/stat 与 /sys/class/hwmon），前端 fs.read 就能拿到，我们包里也早有
 *  对应的 rpcd ACL。所以这里把采集放在前端做：少两处改动、少一个 shell 脚本、
 *  少一个每 5 秒 fork 一次的 `top -n1`，**输出格式仍与 tempinfo 逐字一致**。
 *
 *  ── 取值口径（对着 ImmortalWrt 的 /sbin/tempinfo 抄的）────────────────
 *      CPU 组：/sys/class/thermal/thermal_zone0/temp  ← 我们取 hwmon 里
 *              name=cpu_thermal 的那个（同一颗传感器）
 *      WiFi 组：/sys/class/ieee80211/ 下每个 phyN 的 hwmonM/temp1_input
 *              ← 我们枚举 /sys/class/hwmon/hwmonN，按 name 归类，
 *                等价、而且不怕 hwmon 编号变
 *      拼接：'CPU: 58.4°C' + ', ' + 'WiFi: 44.0°C 44.0°C'
 *      （每个值后面本来有个空格，tempinfo 用 `awk '$1=$1'` 把尾部空格吃掉了，
 *        这里用 join(' ') 得到同样结果）
 *      单位：sysfs 是毫摄氏度，除 1000；保留一位小数。
 *      退化：只有 CPU 就只输出 'CPU: …'，只有 WiFi 就只输出 'WiFi: …'。
 *      注意：这一段是 **块注释**，注释正文里绝对不能出现星号加斜杠的组合
 *            （写通配路径时最容易手滑），否则注释会提前结束、整段变语法错误。
 *            本次就踩过：写成 phy 星号 斜杠 hwmon 星号 斜杠 temp1_input，
 *            node --check 立刻报 Invalid regular expression。所以下面一律
 *            用 phyN / hwmonM 这种占位写法。
 *
 *  ── 文案为什么硬编码中文 ──────────────────────────────────────────────
 *  同 ImmortalWrt 用 _('Temperature')/_('CPU usage (%)')，但那两个 msgid
 *  在**上游** luci-base 的 po/zh_Hans/base.po 里没有（实测 grep 为空），
 *  照抄会显示英文。本版固件只有中文界面，直接写中文最可预测。
 *
 *  ── 时序 ─────────────────────────────────────────────────────────────
 *  index.js 每 5 秒重新调一次本模块的 load()/render()，所以 /proc/stat 的
 *  上一次采样可以存在模块级变量里做差分（top / vmstat 的做法）。首屏没有
 *  上一次采样，就自己补一次 300ms 后的采样，免得首页干等 5 秒才出数字。
 * ========================================================================== */

var AGS21_HWMON_DIR = '/sys/class/hwmon';

/* 上一次 /proc/stat 采样（模块级：L.require 只求值一次） */
var ags21StatPrev = null;

function ags21IsWireless(name) {
	return /phy|mt79|wlan|wifi|radio/i.test(name);
}

function ags21OneTemp(dir) {
	return Promise.all([
		L.resolveDefault(fs.read(dir + '/name'), null),
		L.resolveDefault(fs.read(dir + '/temp1_input'), null)
	]).then(function(r) {
		/* 没有 temp1_input 的 hwmon 不是温度传感器 */
		if (r[1] == null)
			return null;

		var raw = parseInt(String(r[1]).trim(), 10);

		if (!isFinite(raw))
			return null;

		return {
			name: (r[0] != null && String(r[0]).trim() !== '')
				? String(r[0]).trim() : dir.replace(/.*\//, ''),
			text: '%.1f°C'.format(raw / 1000)
		};
	}).catch(function() { return null; });
}

/* 返回 'CPU: 58.4°C, WiFi: 44.0°C 44.0°C' 这样的串；读不到返回 null */
function ags21Temps() {
	return L.resolveDefault(fs.list(AGS21_HWMON_DIR), []).then(function(entries) {
		var dirs = (entries || []).filter(function(e) {
			return /^hwmon\d+$/.test(e.name);
		}).map(function(e) { return AGS21_HWMON_DIR + '/' + e.name; }).sort();

		return dirs.length ? Promise.all(dirs.map(ags21OneTemp)) : [];
	}).then(function(list) {
		var cpu = [], wifi = [], seen = {};

		(list || []).forEach(function(t) {
			if (t == null || seen[t.name])
				return;

			seen[t.name] = true;
			(ags21IsWireless(t.name) ? wifi : cpu).push(t.text);
		});

		var parts = [];

		if (cpu.length)
			parts.push('CPU: ' + cpu.join(' '));
		if (wifi.length)
			parts.push('WiFi: ' + wifi.join(' '));

		return parts.length ? parts.join(', ') : null;
	}).catch(function() { return null; });
}

function ags21ParseStat(data) {
	var out = null;

	String(data || '').split('\n').forEach(function(line) {
		if (out != null)
			return;

		var m = /^cpu\s+(.+)$/.exec(line.trim());

		if (m == null)
			return;

		var f = m[1].trim().split(/\s+/).map(Number),
		    total = 0, i;

		for (i = 0; i < f.length; i++)
			total += (f[i] || 0);

		/* 字段序：user nice system idle iowait irq softirq steal …
		 * 空闲按 idle + iowait 算，和 busybox top 的 %idle 口径一致 */
		out = { idle: (f[3] || 0) + (f[4] || 0), total: total };
	});

	return out;
}

function ags21ReadStat() {
	return L.resolveDefault(fs.read('/proc/stat'), '').then(ags21ParseStat);
}

function ags21Usage(cur, prev) {
	if (cur == null || prev == null)
		return null;

	var dt = cur.total - prev.total;

	if (dt <= 0)
		return null;

	var v = Math.round(100 * (1 - (cur.idle - prev.idle) / dt));

	return '%d%%'.format(Math.max(0, Math.min(100, v)));
}

/* 返回 '28%'；读不到返回 null */
function ags21CPUUsage() {
	if (ags21StatPrev != null) {
		return ags21ReadStat().then(function(now) {
			var r = ags21Usage(now, ags21StatPrev);

			if (now != null)
				ags21StatPrev = now;

			return r;
		});
	}

	return ags21ReadStat().then(function(first) {
		if (first == null)
			return null;

		return new Promise(function(resolve) {
			setTimeout(function() {
				ags21ReadStat().then(function(second) {
					var base = (second != null) ? second : first;

					ags21StatPrev = base;
					resolve(ags21Usage(base, first));
				});
			}, 300);
		});
	}).catch(function() { return null; });
}

/* ======================== AGS21 注入段结束 ======================== */
