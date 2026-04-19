import json

def diagnose(domain, ip_address=None):
    print(f"--- 诊断域名: {domain} ---")
    
    # 模拟 ProxyManager.swift 中的规则顺序
    # 按照我们之前的逻辑，看看匹配顺序
    rules = [
        {"name": "DNS Hijack (Port 53)", "match": lambda d, p: p == 53, "outbound": "dns-out"},
        
        # 这一块是你有疑虑的地方：GeoSite 规则
        {"name": "GeoSite: CN", "match": lambda d, p: d.endswith(".cn") or "sina" in d or "douyin" in d, "outbound": "direct"},
        
        # 模拟订阅规则（假设订阅里有 cloud 关键字）
        {"name": "Sub Rule: DOMAIN-KEYWORD, cloud", "match": lambda d, p: "cloud" in d, "outbound": "proxy"},
        
        # 模拟 GeoIP
        {"name": "GeoIP: CN", "match": lambda d, p: ip_address and ip_address.startswith("110.43"), "outbound": "direct"},
        
        # 默认规则
        {"name": "Final Action", "match": lambda d, p: True, "outbound": "proxy"}
    ]

    matched = False
    for rule in rules:
        if rule["match"](domain, 443):
            print(f"匹配成功! \n规则名称: {rule['name']} \n目标出口: {rule['outbound']}")
            matched = True
            
            if rule['name'] == "Sub Rule: DOMAIN-KEYWORD, cloud":
                print("\n[警告] 发现‘截胡’现象！")
                print(f"解析：由于域名包含 'cloud'，它在进入 GeoIP 判断之前就被订阅规则拦截到了 Proxy。")
                print(f"这就是为什么虽然它是国内域名，却走了代理的原因。")
            break

# 模拟分析
diagnose("cdn.sinacloud.net", "110.43.0.1")
print("\n" + "="*30 + "\n")
diagnose("douyin.com", "122.14.0.1")
