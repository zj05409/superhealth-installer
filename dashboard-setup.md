# SuperHealth Dashboard 初次配置指南

安装完成后，打开 Dashboard：

```text
http://<服务器公网 IP>:8501
```

建议先进入「系统配置」，依次完成 Garmin、建议大模型和消息推送配置，然后保存并测试。

DeepSeek API Key 不在 Dashboard 里填写。它应在腾讯云轻量应用服务器的 SuperHealth 应用初始/基础配置里设置。

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
4. 回到腾讯云轻量应用服务器控制台：
   https://console.cloud.tencent.com/lighthouse/instance/index
5. 打开客户购买的 SuperHealth 服务器实例，进入「应用」相关页面，在初始配置/基础配置里填写 DeepSeek API Key。

不要把 DeepSeek API Key 填到 Dashboard 的系统配置里；Dashboard 里主要配置 Garmin、建议大模型、消息推送，以及后续需要人工维护的用户侧配置。

## 3. 百川大模型 API

百川可作为备用或文档/多模型配置使用。

1. 注册并登录百川大模型平台：
   https://platform.baichuan-ai.com/
2. 充值：
   https://platform.baichuan-ai.com/console/recharge
3. 创建 API KEY：
   https://platform.baichuan-ai.com/console/apikey
4. 打开 Dashboard，进入「系统配置」里的「建议大模型」部分。
5. 在「建议大模型」中填写百川 API Key、Base URL 和模型名，然后保存并测试。

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
