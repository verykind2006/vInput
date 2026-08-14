# 开发期签名身份

## 为什么需要

vInput 需要两项系统授权：

- **辅助功能** —— 注入文字（`CGEvent`）、抑制遥控器杂键（`CGEvent.tapCreate`）
- **输入监控** —— 遥控器返回键取消

macOS 把这两项授权绑定在**代码签名指纹**上。`build-app.sh` 默认用 ad-hoc
签名（`codesign --sign -`），它的指纹由二进制内容算出，因此**每改一行代码
重新打包，系统就认为这是另一个应用，两项授权全部作废**。

开发期这意味着每次构建后都要去系统设置里重新授权，且必须完全退出应用再
打开。实际开发中这条摩擦极其消耗时间——M3 期间它一度让人误判为功能故障。

用一张固定的自签名证书签名，指纹就不再随构建变化，**授权一次长期有效**。

## 创建

证书只用于本机开发，不用于分发。只写入你的**登录钥匙串**，不碰系统钥匙串，
不需要 sudo。

```bash
# 1. 生成自签名证书（有效期 10 年）
cd "$(mktemp -d)"
cat > ext.cnf <<'EOF'
[req]
distinguished_name=dn
x509_extensions=v3
prompt=no
[dn]
CN=vInput Dev
[v3]
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
EOF
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -config ext.cnf -keyout k.pem -out c.pem

# 2. 导入钥匙串
#    必须指定这三个 PBE 参数：OpenSSL 3 默认用 AES-256 + SHA-256 生成 p12，
#    macOS 的 security 命令读不了，会报 "MAC verification failed"。
openssl pkcs12 -export -inkey k.pem -in c.pem -out id.p12 \
  -name "vInput Dev" -passout pass:vinput \
  -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1
security import id.p12 -k ~/Library/Keychains/login.keychain-db \
  -P vinput -T /usr/bin/codesign -A

# 3. 标记为可信的代码签名证书（会弹系统密码框）
#    没有这一步，security find-identity 会显示 "0 valid identities"。
mkdir -p ~/.config/vinput
cp c.pem ~/.config/vinput/dev-signing-cert.pem
security add-trusted-cert -r trustRoot -p codeSign \
  -k ~/Library/Keychains/login.keychain-db ~/.config/vinput/dev-signing-cert.pem
```

验证：

```bash
security find-identity -v -p codesigning   # 应列出 "vInput Dev"
```

`build-app.sh` 会自动检测并使用它，找不到则退回 ad-hoc。

## 撤销

打开「钥匙串访问」，在「登录」钥匙串里删除名为 `vInput Dev` 的证书和私钥，
再删掉 `~/.config/vinput/`。之后 `build-app.sh` 自动退回 ad-hoc 签名。

## 注意

**换用固定身份后需要再授权一次**（指纹从 ad-hoc 变成了新证书），此后不再
需要。授权时记得先完全退出旧进程。
