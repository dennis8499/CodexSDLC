"use strict";
var __createBinding = (this && this.__createBinding) || (Object.create ? (function(o, m, k, k2) {
    if (k2 === undefined) k2 = k;
    var desc = Object.getOwnPropertyDescriptor(m, k);
    if (!desc || ("get" in desc ? !m.__esModule : desc.writable || desc.configurable)) {
      desc = { enumerable: true, get: function() { return m[k]; } };
    }
    Object.defineProperty(o, k2, desc);
}) : (function(o, m, k, k2) {
    if (k2 === undefined) k2 = k;
    o[k2] = m[k];
}));
var __setModuleDefault = (this && this.__setModuleDefault) || (Object.create ? (function(o, v) {
    Object.defineProperty(o, "default", { enumerable: true, value: v });
}) : function(o, v) {
    o["default"] = v;
});
var __importStar = (this && this.__importStar) || (function () {
    var ownKeys = function(o) {
        ownKeys = Object.getOwnPropertyNames || function (o) {
            var ar = [];
            for (var k in o) if (Object.prototype.hasOwnProperty.call(o, k)) ar[ar.length] = k;
            return ar;
        };
        return ownKeys(o);
    };
    return function (mod) {
        if (mod && mod.__esModule) return mod;
        var result = {};
        if (mod != null) for (var k = ownKeys(mod), i = 0; i < k.length; i++) if (k[i] !== "default") __createBinding(result, mod, k[i]);
        __setModuleDefault(result, mod);
        return result;
    };
})();
Object.defineProperty(exports, "__esModule", { value: true });
exports.nodeDecorations = void 0;
exports.toTreeItem = toTreeItem;
const vscode = __importStar(require("vscode"));
// FileDecoration 能讓樹節點的文字跟著主題上色，ThemeIcon 的顏色只用於圖示。
const DECO_SCHEME = 'codex-sdlc-node';
const ACCENT = 'codexSdlc.accent';
const toneColor = {
    ok: undefined,
    warn: 'list.warningForeground',
    error: 'list.errorForeground',
    pending: ACCENT,
    muted: 'disabledForeground',
    accent: ACCENT,
};
// 只有要人注意的節點才連文字一起上色。
const labelColor = { warn: toneColor.warn, error: toneColor.error, pending: ACCENT, accent: ACCENT };
function toTreeItem(n, media) {
    const state = n.children && n.children.length > 0
        ? (n.expanded ? vscode.TreeItemCollapsibleState.Expanded : vscode.TreeItemCollapsibleState.Collapsed)
        : vscode.TreeItemCollapsibleState.None;
    const item = new vscode.TreeItem(n.label, state);
    item.id = n.id;
    item.description = n.description;
    item.tooltip = n.tooltip;
    item.contextValue = n.contextValue;
    const color = n.tone ? toneColor[n.tone] : undefined;
    if (n.iconFile) {
        // 異常圖示兩種主題共用一張，其他圖示分淺色、深色各一張。
        item.iconPath = n.iconFile.endsWith('-error')
            ? media(`${n.iconFile}.svg`)
            : { light: media(`${n.iconFile}-light.svg`), dark: media(`${n.iconFile}-dark.svg`) };
    }
    else if (n.icon) {
        item.iconPath = new vscode.ThemeIcon(n.icon, color ? new vscode.ThemeColor(color) : undefined);
    }
    if (n.command)
        item.command = n.command;
    if (n.tone && labelColor[n.tone]) {
        item.resourceUri = vscode.Uri.from({ scheme: DECO_SCHEME, path: `/${n.id}`, query: n.tone });
        // 沒有 tooltip 時，VS Code 會把裝飾用的 URI 當成檔案路徑顯示。
        item.tooltip ??= n.label;
    }
    // 行尾的 ● 提供視覺提示，螢幕閱讀器需要讀出「未套用」。
    if (n.tone === 'pending')
        item.accessibilityInformation = { label: `${n.label} ${n.description ?? ''} 未套用` };
    return item;
}
exports.nodeDecorations = {
    provideFileDecoration(uri) {
        if (uri.scheme !== DECO_SCHEME)
            return undefined;
        const tone = uri.query;
        const color = labelColor[tone];
        return color ? new vscode.FileDecoration(tone === 'pending' ? '●' : undefined, tone === 'pending' ? '未套用' : undefined, new vscode.ThemeColor(color)) : undefined;
    },
};
