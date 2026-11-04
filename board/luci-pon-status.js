'use strict';
'require view';
'require fs';
'require ui';

/*
 * 轻量 PON 页面：状态显示 + 线路模式切换
 * 不依赖 airoha-ponctl（Rust），全部走 /usr/bin 下的 shell 脚本。
 */

var MODES = [
	[ 'xgpon',        'XG-PON   (下行 10G / 上行 2.5G)' ],
	[ 'gpon',         'GPON     (下行 2.5G / 上行 1.25G)' ],
	[ 'xgspon',       'XGS-PON  (上下行对称 10G)' ],
	[ 'epon-10g-10g', '10G-EPON (对称)' ],
	[ 'epon-10g-1g',  '10G-EPON (非对称)' ],
	[ 'epon-1g',      'EPON 1G' ]
];

function currentMode(out) {
	var m = (out || '').match(/configured_mode:\s*(\S+)/);
	return m ? m[1] : null;
}

return view.extend({
	load: function() {
		return fs.exec('/usr/bin/pon-selftest');
	},

	handleRefresh: function() {
		var self = this;
		return this.load().then(function(res) {
			var out = (res && res.stdout) ? res.stdout : '(无输出)';
			var pre = document.getElementById('pon-selftest-out');
			if (pre) pre.textContent = out;
			var badge = document.getElementById('pon-mode-badge');
			if (badge) badge.textContent = currentMode(out) || '(未知)';
		});
	},

	handleApply: function() {
		var sel = document.getElementById('pon-mode-select');
		var mode = sel ? sel.value : null;
		if (!mode)
			return;

		ui.showModal(_('切换 PON 线路模式'), [
			E('p', {}, _('正在切换到 %s 并重新拉起 pon0，大约需要 15 秒 …').format(mode))
		]);

		return fs.exec('/usr/bin/pon-mode', [ mode ]).then(function(res) {
			ui.hideModal();
			var out = (res && res.stdout) ? res.stdout.trim() : '';
			ui.addNotification(null,
				E('div', {}, [
					E('p', {}, _('已切换为 %s').format(mode)),
					E('pre', { 'style': 'font-size:12px;white-space:pre-wrap;' }, out)
				]),
				'success');
			return this.handleRefresh();
		}.bind(this)).catch(function(e) {
			ui.hideModal();
			ui.addNotification(null, E('p', {}, _('切换失败：') + e), 'danger');
		});
	},

	handleRestart: function() {
		return fs.exec('/usr/bin/pon-restart').then(function(res) {
			ui.addNotification(null,
				E('p', {}, _('PON 接口已重启：') + ((res && res.stdout) ? res.stdout.trim() : '')),
				'info');
			return this.handleRefresh();
		}.bind(this));
	},

	render: function(res) {
		var out = (res && res.stdout) ? res.stdout : '(无输出)';
		var mode = currentMode(out);

		var select = E('select', { 'id': 'pon-mode-select', 'class': 'cbi-input-select' },
			MODES.map(function(m) {
				return E('option', { 'value': m[0], 'selected': (m[0] === mode) ? 'selected' : null },
					m[1]);
			}));

		return E([], [
			E('h2', {}, _('PON 状态')),
			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('线路模式')),
				E('div', { 'class': 'cbi-section-descr' }, _(
					'当前配置模式：'
				), E('strong', { 'id': 'pon-mode-badge' }, mode || '(未知)')),
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title' }, _('切换到')),
					E('div', { 'class': 'cbi-value-field' }, [
						select,
						E('button', {
							'class': 'btn cbi-button cbi-button-apply',
							'style': 'margin-left:8px',
							'click': ui.createHandlerFn(this, 'handleApply')
						}, _('应用'))
					])
				]),
				E('div', { 'class': 'cbi-section-descr' }, _(
					'不知道线路类型时逐个试：切换后等 15~20 秒看下方 xgtc_sync 是否离开 hunt。' +
					'锁上了就说明模式对了。'
				))
			]),
			E('div', { 'class': 'cbi-page-actions' }, [
				E('button', {
					'class': 'btn cbi-button cbi-button-action',
					'click': ui.createHandlerFn(this, 'handleRefresh')
				}, _('刷新状态')),
				' ',
				E('button', {
					'class': 'btn cbi-button cbi-button-reset',
					'click': ui.createHandlerFn(this, 'handleRestart')
				}, _('重启 PON 接口'))
			]),
			E('pre', {
				'id': 'pon-selftest-out',
				'style': 'white-space: pre-wrap; font-size: 12px; line-height: 1.45; ' +
					 'background: #f5f5f5; padding: 12px; border-radius: 4px; ' +
					 'max-height: 65vh; overflow: auto;'
			}, out)
		]);
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
