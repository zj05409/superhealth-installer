# SuperHealth Dashboard 初次配置指南

安装完成后，打开 Dashboard：

```text
http://<服务器公网 IP>:8501
```

建议先进入「系统配置」，依次完成 Garmin、消息推送和大模型配置，然后保存并测试。

## 1. Garmin Connect

在 Dashboard 的 Garmin 配置区填写你的 Garmin Connect 中国区账号和密码。

- 中国区 Garmin Connect 使用 `connect.garmin.cn`
- 账号通常是手机号或邮箱
- 保存后使用 Dashboard 中的测试/同步按钮验证

## 2. DeepSeek API

DeepSeek 适合做主要健康建议和日报分析模型。

1. 注册并登录 DeepSeek 开放平台：
   https://platform.deepseek.com/
2. 充值：
   https://platform.deepseek.com/top_up
3. 创建 API KEY：
   https://platform.deepseek.com/api_keys
4. 在 Dashboard 的大模型配置中填写：
   - API Key
   - Base URL: `https://api.deepseek.com`
   - Model: 可先使用 `deepseek-chat`

## 3. 百川大模型 API

百川可作为备用或文档/多模型配置使用。

1. 注册并登录百川大模型平台：
   https://platform.baichuan-ai.com/
2. 充值：
   https://platform.baichuan-ai.com/console/recharge
3. 创建 API KEY：
   https://platform.baichuan-ai.com/console/apikey
4. 在 Dashboard 对应的大模型配置中填写 API Key、Base URL 和模型名。

## 4. 消息推送

安装脚本会自动检测服务器上的 Hermes 或 OpenClaw，并尽量写入 `[channel]` 配置。

保存配置后，建议在 Dashboard 中发送一条测试消息，确认报告可以推送到微信。

## 5. 保存后检查

配置保存后，服务器上的配置文件是：

```text
~/.superhealth/config.toml
```

如需排查服务状态：

```bash
systemctl --user status superhealth-dashboard.service
systemctl --user status superhealth-vitals-receiver.service
tail -f ~/.superhealth/install.log
```
