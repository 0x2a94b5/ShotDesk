#!/bin/bash
# 创建一个自签名代码签名证书，让屏幕录制授权绑在证书上而不是二进制哈希上。
# 配好之后重新编译 ShotDesk 不会再让授权失效。只需要跑一次。
set -euo pipefail

CERT_NAME="ShotDesk Dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
[ -f "$KEYCHAIN" ] || KEYCHAIN="$HOME/Library/Keychains/login.keychain"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$CERT_NAME"; then
    echo "✅ 证书「$CERT_NAME」已经存在，无需重复创建。"
    echo "   直接跑 ./build.sh 即可，它会自动用这张证书签名。"
    exit 0
fi

# 私钥落在临时目录，结束后立刻删除
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "==> 生成自签名证书"
# 系统自带的是 LibreSSL，不支持 -addext，只能用配置文件写扩展
cat > "$WORK/cfg" <<EOF
[ req ]
distinguished_name = dn
x509_extensions = v3
prompt = no
[ dn ]
CN = $CERT_NAME
[ v3 ]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
EOF

/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
    -config "$WORK/cfg" -extensions v3 >/dev/null 2>&1

# 不能用空密码：LibreSSL 导出的空密码 p12，macOS Security 框架验不过 MAC
# (空密码在 PKCS#12 里有 空字符串 vs NULL 的编码歧义，两边实现不一致)
P12PASS="$(/usr/bin/openssl rand -hex 16)"
/usr/bin/openssl pkcs12 -export -out "$WORK/cert.p12" \
    -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
    -passout "pass:$P12PASS" -name "$CERT_NAME" >/dev/null 2>&1

echo "==> 导入登录钥匙串"
if ! security import "$WORK/cert.p12" -k "$KEYCHAIN" -P "$P12PASS" -T /usr/bin/codesign >/dev/null; then
    echo "❌ 导入钥匙串失败。"
    echo "   可改用图形界面：钥匙串访问 → 证书助理 → 创建证书…"
    echo "   名称 $CERT_NAME，身份类型「自签名根证书」，证书类型「代码签名」"
    exit 1
fi

echo "==> 设置为受信任的代码签名证书"
echo "    这一步不能省：未受信任的证书，codesign 会直接报「钥匙串里找不到该项」。"
echo "    系统会弹窗要你的登录密码（这是在改证书信任设置），输入即可。"
if ! security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$WORK/cert.pem"; then
    echo "❌ 设置信任失败（取消了密码输入？）。证书已导入但不可用于签名。"
    echo "   可以手动补：钥匙串访问 → 登录 → 找到「$CERT_NAME」→ 右键显示简介"
    echo "   → 展开「信任」→ 把「代码签名」设为「始终信任」"
    exit 1
fi

echo ""
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$CERT_NAME"; then
    echo "✅ 证书创建成功"
    security find-identity -v -p codesigning | grep "$CERT_NAME"
    echo ""
    echo "接下来："
    echo "  1. ./build.sh                                      # 会自动用这张证书签名"
    echo "     第一次签名时系统会弹窗问是否允许 codesign 使用钥匙串里的密钥，"
    echo "     点「始终允许」，以后就不会再问了"
    echo "  2. tccutil reset ScreenCapture com.shotdesk.app     # 清掉旧的授权记录"
    echo "  3. open build/ShotDesk.app，按热键后授权屏幕录制一次"
    echo ""
    echo "之后再怎么改代码重新编译，屏幕录制授权都不会掉。"
else
    echo "❌ 证书导入了，但没出现在「有效」签名身份列表里（通常是信任没设上）。"
    echo "   手动补：钥匙串访问 → 登录 → 找到「$CERT_NAME」→ 右键显示简介"
    echo "   → 展开「信任」→「代码签名」设为「始终信任」，然后重跑 ./build.sh"
    echo ""
    echo "   可以改用图形界面创建：钥匙串访问 → 证书助理 → 创建证书…"
    echo "   名称 $CERT_NAME，身份类型「自签名根证书」，证书类型「代码签名」"
    exit 1
fi
