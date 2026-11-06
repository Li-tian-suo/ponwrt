'use strict';
'require view';
'require form';
'require fs';
'require ui';
'require poll';
'require uci';

return view.extend({
	load: function() {
		var self = this;

		return Promise.all([
			fs.exec('/etc/init.d/homebox', [ 'running' ]).then(function(res) {
				return res.code === 0;
			}).catch(function() {
				return false;
			}),
			uci.load('homebox').then(function() {
				return uci.get('homebox', 'main', 'port') || '3300';
			}).catch(function() {
				return '3300';
			})
		]).then(function(res) {
			self.port = res[1];
			return res[0];
		});
	},

	render: function(running) {
		var self = this;
		var port = this.port || '3300';
		var statusEl;

		var setStatus = function(up) {
			statusEl.style.color = up ? '#2e7d32' : '#c62828';
			statusEl.textContent = up ? _('运行中') : _('已停止');
		};

		var refresh = function() {
			return fs.exec('/etc/init.d/homebox', [ 'running' ]).then(function(res) {
				setStatus(res.code === 0);
				return res.code === 0;
			}).catch(function() {
				setStatus(false);
				return false;
			});
		};

		var doAction = function(action) {
			return fs.exec('/etc/init.d/homebox', [ action ]).then(function() {
				return new Promise(function(resolve) { setTimeout(resolve, 1500); });
			}).then(refresh).then(function(up) {
				ui.addNotification(null, E('p', _('操作完成，当前状态：%s').format(up ? _('运行中') : _('已停止'))), 'info');
			}).catch(function() {
				ui.addNotification(null, E('p', _('操作失败，请查看系统日志')), 'error');
			});
		};

		var mkButton = function(label, action, style) {
			return E('button', {
				'class': 'cbi-button cbi-button-' + style,
				'style': 'margin-right:8px',
				'click': function() { return doAction(action); }
			}, [ label ]);
		};

		statusEl = E('span', {
			'style': 'font-weight:bold;color:' + (running ? '#2e7d32' : '#c62828')
		}, running ? _('运行中') : _('已停止'));

		var m = new form.Map('homebox', _('Homebox 内网测速'),
			_('Homebox 在路由器上运行一个测速服务端，用浏览器打开测速页面即可测试内网真实吞吐。' +
			  '默认监听 3300 端口，例如 http://192.168.1.1:3300 。' +
			  '注意：本服务无认证，请勿直接暴露到公网。'));
		var s = m.section(form.NamedSection, 'main', 'homebox', _('服务设置'));
		s.anonymous = true;

		var o = s.option(form.Flag, 'enabled', _('开机自启'));
		o.default = '1';
		o.rmempty = false;

		o = s.option(form.Value, 'host', _('监听地址'));
		o.default = '0.0.0.0';
		o.datatype = 'ipaddr';
		o.rmempty = false;

		o = s.option(form.Value, 'port', _('监听端口'));
		o.default = '3300';
		o.datatype = 'port';
		o.rmempty = false;

		o = s.option(form.Value, 'workers', _('工作线程数'),
			_('留空使用服务端默认值。CPU 较弱时建议留空。'));
		o.datatype = 'uinteger';
		o.placeholder = _('默认');

		o = s.option(form.Value, 'max_connections', _('最大并发连接'),
			_('留空使用服务端默认值。'));
		o.datatype = 'uinteger';
		o.placeholder = _('默认');

		o = s.option(form.Value, 'keep_alive_secs', _('Keep-Alive 超时（秒）'),
			_('留空使用服务端默认值。'));
		o.datatype = 'uinteger';
		o.placeholder = _('默认');

		return m.render().then(function(node) {
			var ctrl = E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, [ _('服务控制') ]),
				E('div', { 'style': 'margin:10px 0' }, [
					_('当前状态：'), statusEl
				]),
				E('div', { 'style': 'margin:10px 0' }, [
					mkButton.call(this, _('启动 / 重启'), 'restart', 'apply'),
					mkButton.call(this, _('停止'), 'stop', 'remove'),
					E('a', {
						'class': 'cbi-button',
						'href': 'http://' + window.location.hostname + ':' + port,
						'target': '_blank',
						'rel': 'noopener'
					}, [ _('打开测速页面') ])
				]),
				E('div', { 'class': 'cbi-section-descr' },
					_('测速时会占用路由器 CPU，属正常现象。建议在测速前关闭下载等占用带宽的任务。'))
			]);

			node.insertBefore(ctrl, node.firstChild);

			poll.add(refresh, 5);

			return node;
		}.bind(this));
	}
});
