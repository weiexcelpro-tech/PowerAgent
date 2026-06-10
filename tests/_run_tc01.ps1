# TC01 E2E Test Runner
$env:PA_ONESHOT_PROMPT = '对 C:\Work\202606\Bash-agent\Testcase\TC01-数据清洗与格式化\原始数据\销售数据.xlsx 进行清洗：删除空行，按"订单号"去重，统一日期格式为YYYY-MM-DD，销售额保留2位小数，输出为"C:\Work\202606\Bash-agent\Testcase\TC01-数据清洗与格式化\销售数据_清洗版.xlsx"'
& "C:\Work\202606\Bash-agent\PowerAgent\PowerAgent.ps1" --oneshot 2>&1
