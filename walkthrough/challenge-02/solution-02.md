# Walkthrough Challenge 2 - Monitoring and Performance on Azure SQL Managed Instance with GitHub Copilot

[Previous Challenge Solution](../challenge-01/solution-01.md) - **[Home](../../Readme.md)** - [Next Challenge Solution](../challenge-03/solution-03.md)

## Monitoring and Performance on Azure SQL Managed Instance with GitHub Copilot

In this challenge **GitHub Copilot is your main tool for finding and fixing performance problems**. You will start with a few prompting basics, then use Copilot to find the bottleneck, understand the root cause, write KQL queries, and fix the problem. The classic tools (DMVs, Query Store, Azure Portal, Log Analytics) are still part of the walkthrough, and you use them to **verify what Copilot tells you**.

### Contents

[Migration architecture and Azure components](#migration-architecture-and-azure-components)

[Lab Overview & Background](#lab-overview--background)

[1. Preparation](#1-preparation)
* [1.1 Connect to the Managed Instance and open the TenantCRM database](#11-connect-to-the-managed-instance-and-open-the-tenantcrm-database)
* [1.2 Open the GitHub Copilot chat](#12-open-the-github-copilot-chat)

[2. Prompting basics: how to talk to GitHub Copilot](#2-prompting-basics-how-to-talk-to-github-copilot)

[3. Find the performance bottleneck with GitHub Copilot](#3-find-the-performance-bottleneck-with-github-copilot)

[4. Verify with DMVs and the Query Store](#4-verify-with-dmvs-and-the-query-store)

[5. Analyze the performance in the Azure Portal](#5-analyze-the-performance-in-the-azure-portal)

[6. Visualize SQL MI and database stats with Log Analytics and KQL](#6-visualize-sql-mi-and-database-stats-with-log-analytics-and-kql)

[7. Fix the performance issue with GitHub Copilot](#7-fix-the-performance-issue-with-github-copilot)

[Prompt cheat sheet](#prompt-cheat-sheet)

# Migration architecture and Azure components

![generated](../../Images/MigrationArchitecturev3.png)

# Lab Overview & Background

In this exercise you will explore how you can monitor and diagnose performance issues with Azure SQL Managed Instance using GitHub Copilot, SQL Server Management Studio, DMVs (Dynamic Management Views) and Azure Portal tools.

## Background

We have seen that the legacy application is a multi-tenant system with a collection of 4 databases supporting the transactional workload for each customer – these are the 4 databases we have modernised by migrating to the shared Azure SQL Managed Instance.

Apart from the tenant centric transactional databases there are 2 shared databases:

* **SharedMasterDataDB**: A centralised Data Warehouse database that combines data from the various tenant transactional databases and is used for aggregated reporting and analytics.
* **TenantCRM**: A centralised database that is used to manage all customer relationships and order processing.

Recently you have heard complaints from users that the TenantCRM system is running slowly. Recently changes were made to some of the stored procedures in the TenantCRM database and the App dev team believe these are the source of the problem. They’ve asked for your help to track down the performance issues and its root cause.

> **Note:** The exercises in this lab are conducted against the shared **TenantCRM** database.

Performance issues in SQL Server can be grouped into 1 of 2 high-level categories: *Running* or *Waiting*.

*Running* means a query has been allocated CPU resource and is actively processing but is taking a long time to complete. *Waiting* means a query is not actively being processed by the CPU but is waiting on another resource (such as memory, disk, network, etc) to pass data in so processing can continue.

Finding the bottleneck will help us determine what category issue we have so we can progress to identifying the root cause.

# 1. Preparation

## 1.1 Connect to the Managed Instance and open the TenantCRM database

|**Narrative/Instructions**| **Screenshot**| **Notes**|
|:------------|:--------------|:---------|
|On your Team Win11 VM open **SQL Server Management Studio (SSMS)** and connect to the Azure SQL Managed Instance XXXXXX. **Authentication: Microsoft Entra MFA** **Login:** **<secret group="Azure" name="Entra ID Username" show="true"></secret>** **TAP:**  **<secret group="Azure" name="Entra ID TAP"></secret>**| **![](../../Images/4b05bbceae6c4c0d2c4e37e53e60dfd4.png)**|If SSMS is not connected to your Azure and GitHub accounts anymore, repeat the account steps from [Challenge 1](../challenge-01/solution-01.md#12-connect-ssms-with-your-azure-and-github-copilot-accounts).|
|In Object Explorer expand **Databases**, right-click **TenantCRM** and select **New Query**. Make sure the query window is connected to the **TenantCRM** database.|![New query window on TenantCRM](../../Images/SSMS_TenantCRM_NewQuery.png)|Copilot uses the connection of the active query window as context.|

## 1.2 Open the GitHub Copilot chat

|**Narrative/Instructions**| **Screenshot**| **Notes**|
|:------------|:--------------|:---------|
|Open the GitHub Copilot chat window in SSMS and verify that you are signed in.|![](../../Images/SSMS_Github_Chat.png)||
|Verify that Copilot sees your database context by asking a first question.|![Copilot confirms the database context](../../Images/Copilot_Database_Context.png)|**Prompt**: *"Which database am I connected to and which tables does it contain?"*|

# 2. Prompting basics: how to talk to GitHub Copilot

The quality of the answer depends on the quality of your question. Before you start, try the same task with a weak and with a strong prompt and compare the results.

| Principle | Weak prompt | Better prompt |
|:----------|:------------|:--------------|
| **Be specific about the target** | *"Why is it slow?"* | *"Why is the TenantCRM database on my Managed Instance slow?"* |
| **Describe the symptom** | *"Check performance."* | *"Users report that TenantCRM is slow since the last stored procedure changes. Check the CPU usage and find the cause."* |
| **Ask for evidence** | *"Fix my query."* | *"Show me the query or DMV you used to find this and explain what the numbers mean."* |
| **Ask for an explanation** | *"Create an index."* | *"Explain why this index helps and what the trade-offs are before you create it."* |
| **Iterate with follow-ups** | *(one single prompt)* | *"Now show me the second most expensive procedure."* |
| **Review before you run** | *(execute everything)* | *"Show me the script first. Do not change anything yet."* |

|**Narrative/Instructions**| **Screenshot**| **Notes**|
|:------------|:--------------|:---------|
|Send a **vague** prompt to Copilot and look at the answer.|![Copilot answer to a vague prompt](../../Images/Copilot_Vague_Prompt.png)|**Prompt**: *"Why is it slow?"*|
|Now send a **specific** prompt that contains the database, the symptom and the expected result. Compare the two answers.|![Copilot answer to a specific prompt](../../Images/Copilot_Specific_Prompt.png)|**Prompt**: *"Users report that the TenantCRM database is slow since the last stored procedure changes. Which queries or stored procedures cause the highest load? Please explain how you found them."*|

> **Tip:** Copilot may ask for approval before it runs queries against your database. Please read what is executed and approve the requests. Copilot should only read data and metadata in this challenge unless you tell it to change something.

# 3. Find the performance bottleneck with GitHub Copilot

|**Narrative/Instructions**| **Screenshot**| **Notes**|
|:------------|:--------------|:---------|
|Ask Copilot to analyze the load of the database. Enter a prompt similar to the following into the GitHub Copilot chat window.|![](../../Images/GithubCopilot_performance_prompt.png)|**Prompt**: *"Please check for queries or stored procedures with the highest load in the TenantCRM database and suggest solutions for possible performance issues."*|
|GitHub Copilot may request approval several times to execute queries to analyze the problem. Please approve the requests.|![](../../Images/GithubCopilot_Approve.png)|**Note**: Look at the queries Copilot executes. You will recognize DMVs such as `sys.dm_exec_query_stats` and the Query Store views.|
|Ask Copilot to explain the category of the problem.|![Copilot classifies the problem as running or waiting](../../Images/Copilot_Running_Or_Waiting.png)|**Prompt**: *"Is the problem in TenantCRM a running problem (CPU) or a waiting problem? Please explain how you decided."*|
|Ask Copilot to rank the most expensive stored procedures.|![Copilot lists the most expensive stored procedures](../../Images/Copilot_Top_Procedures.png)|**Prompt**: *"Show me the top 5 stored procedures by total CPU time (total_worker_time) in TenantCRM, including execution count and average CPU time per execution."*|
|Note the name of the most CPU consuming stored procedure. You will need it in the next steps.|||

# 4. Verify with DMVs and the Query Store

GitHub Copilot is a great assistant, but you should **always verify** its findings. In this section you reproduce the result with the lab scripts and the built-in Query Store reports. Use Copilot to explain what you see.

|**Narrative/Instructions**| **Screenshot**| **Notes**|
|:------------|:--------------|:---------|
|**Open** the SQL script:  C:\\MicroHack\\LABS\\02-Administering_Monitoring\\Part_01_Monitoring_Lab_1.sql  <br>    <br>  **Note:** Make sure you connect with the **TenantCRM** database.    <br>  <br>  Run the **PART 1** QUERY 1.  Look at the results and note the [avg_cpu_percent] value is spiking many times indicating that this database is consuming a lot of the hosts CPU resources|![](../../Images/f813232846539c9b2785ea44f8883e94.png)| [[sys].[dm_db_resource_stats]](https://docs.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-views/sys-dm-db-resource-stats-azure-sql-database?view=azuresqldb-current) exposes a number of key database performance metrics.  One metric every 15 seconds over the last hour.<br>**Prompt**: *"Explain the result of this query and what the avg_cpu_percent column tells me."* (select the query in the editor first)|
|Now let’s try the second query to analyze the resource consumption.  <br>  **Execute** QUERY 2 and analyze the values during the last minutes. You will see spikes in CPU consumption.|| If more than 1 hour of statistics is needed, use the DMV [[sys].[server_resource_stats]](https://docs.microsoft.com/en-us/sql/relational-databases/system-catalog-views/sys-server-resource-stats-azure-sql-database?view=azuresqldb-current) up to 14 days.<br>**Prompt**: *"How can I look at more than one hour of CPU history on a Managed Instance?"*|
|**Open** the SQL script:  C:\\MicroHack\\LABS\\02-Administering_Monitoring\\Part_02_Monitoring_Lab_1.sql  <br>    <br>  **Note:** Make sure you connect with the **TenantCRM** database.    <br>  <br>  **Run** the **PART 2** QUERY 1.<br> Identify the most consuming stored procedure based on the total_worker_time (CPU). Compare the result with the answer from Copilot.|![](../../Images/ad69a5f2a781f8c634d6522000027a1a.png)|**Prompt**: *"Does this result match your analysis? If not, explain the difference."*|
|Then to have further details on the most consuming stored procedure **Run** the **PART 2** QUERY 2, replace the filter clause with the stored procedure name. What is the issue? How to optimise?  **Tip:** Have a look to the execution plan| **CROSS APPLY and Table-valued Functions**<br> The PART 2 query joins the [sys].[dm_exec_requests] and [sys].[dm_exec_sql_text] DMVs to obtain long running batches and critically their offending SQL.  Note that [dm_exec_sql_text] is actually a table-valued function (TVF) hence the use of the CROSS APPLY as TVFs can't be used in a normal join operation. The CROSS APPLY therefore produces the required inner-join between [dm_exec_requests] and [dm_exec_sql_text].<br> See APPLY documentation here: [Using APPLY \| Microsoft Docs](https://docs.microsoft.com/en-us/previous-versions/sql/sql-server-2008-r2/ms175156(v=sql.105)?redirectedfrom=MSDN) and this excellent explanation on MSSQLTips: [SQL Server CROSS APPLY and OUTER APPLY (mssqltips.com)](https://www.mssqltips.com/sqlservertip/1958/sql-server-cross-apply-and-outer-apply/#:~:text=The%20CROSS%20APPLY%20operator%20returns%20only%20those%20rows,rows%20for%20the%20left%20table%20expression%20match%20only.)<br>**Prompt**: *"Why is this stored procedure so expensive? Please look at its code and its execution plan."*||
| In SSMS expand the [TenantCRM] database then expand Query Store.Remember that the Query Store collects telemetry data every 15 seconds and persists it for about 1hr.  Double click on **Overall Resource Consumption** report to open it.| ![](../../Images/7e23b421dd7ec737ca5a61692ed7d03d.png)||
| For further details CPU Time, double click on the current day bar| ![](../../Images/3d128986226374d9cc0b8afeff0bb6e6.png)||
| You can identify the top CPU consuming queries.  Click on bars for more details| ![](../../Images/954f6dfa708564bef81ec0f46ee77bd7.png) |**Prompt**: *"What is the Query Store and how does it help me to find regressed queries?"*|

# 5. Analyze the performance in the Azure Portal

As we are using Azure SQL Managed Instance we can also use the richness of the Azure Portal to help us to troubleshoot performance issues. GitHub Copilot in SSMS cannot see the Azure Portal, so use it here as a **guide that explains the metrics** while you look at the portal.

|**Narrative/Instructions**| **Screenshot**| **Notes**|
|:------------|:--------------|:---------|
| Open the Azure Portal (portal.azure.com) and open the shared SQL Managed Instance.  Scroll down the **Overview** screen until you see the performance graph showing CPU utilization.  Toggle the switches next to view CPU consumption over 1 hour, 24 hours and 7 days.   Has the CPU usage pattern changed over time?     | ![](../../Images/87dbf84394a8aa06fb53d5985eaaa0aa.png) |**Prompt**: *"Which metrics of an Azure SQL Managed Instance should I check first when users report a slow database, and what do they tell me?"*|
| Click into the graph to go into Metrics chart screen. Here you have more flexibility over the data being reported and the format of the chart. Let’s add Storage Space Used the chart.   Click **Add Metric**   In the Metric drop down select **Storage Space Used**.  .  | ![](../../Images/6daca573871745a2ac17e9c65da58aa7.png) | Notice that from the chart screen you can alter the type of chart (Line, Area, Bar, Scatter to data Grid), set up alerts, and pin the chart to your Azure Portal dashboard. |
| Click **Local Time** on the top right of the chart to view the data for various time intervals.|![](../../Images/b0766aea6531c7cbf9d482aee37d4c84.png)||
|Describe what you see in the chart to Copilot and ask for an interpretation.|![Copilot interprets the CPU chart](../../Images/Copilot_Interprets_CPU_Chart.png)|**Prompt**: *"In the Azure Portal the CPU utilization of my Managed Instance shows repeated spikes up to 90 percent. What could be the reasons and how do I find the responsible queries?"*|

# 6. Visualize SQL MI and database stats with Log Analytics and KQL

Now that we can use the global monitoring tool Log Analytics to identify which SQL Managed Instance consumes the resources, let Copilot help you with the Kusto Query Language (KQL).

|**Narrative/Instructions**| **Screenshot**| **Notes**|
|:------------|:--------------|:---------|
|Ask Copilot to generate a KQL query for you.|![Copilot generates a KQL query](../../Images/Copilot_KQL_Generate_00.png)<br>![](../../Images/Copilot_KQL_Generate_01.png)|**Prompt**: *"Write a KQL query for the AzureDiagnostics table that shows the average CPU percentage of my SQL Managed Instance over the last 2 hours as a time chart."*|
|On the Azure Portal, on the SQL Managed Instance Resource, **click on Logs** on the left Menu. You will find several query templates You can test the **CPU utilization threshold template** And modify the parameters if needed.|![](../../Images/7ac7f4ea0bf678241cccc8d2bc0e348f.png)||
||**![](../../Images/ce136344cc4d9c981d780e733b4260d7.png)**||
|Create a new Query| ![](../../Images/ef049ae85146b0b3e9a80c2ccd6cbb58.png)||
|Paste the query from Copilot and run it|![](../../Images/Copilot_KQL_Generate_02.png)<br>![](../../Images/Copilot_KQL_Generate_03.png)||
|Try the following queries (replace the SQLMI name). AzureDiagnostics is the table receiving the different diagnostics. Modify the Time Range, By default 24hours <br> <br> ![](../../Images/7d9ba55500e1cb33c5296437df11b02a.png)|//general queries <br> // query 1 without filter<br> AzureDiagnostics <br><br> // query 2 SQL MI Resource usage <br> AzureDiagnostics<br> \| where Resource =~ "SQLHACKMI-WORWEGR7VULCU" //replace with your SQL MI Instance Name <br>\| where Category == "ResourceUsageStats" <br><br> // query 3 on database: waits Stats <br> AzureDiagnostics<br> \| where Resource =~ "TENANTCRM"<br> \| where Category == "QueryStoreWaitStatistics" <br><br> // query 4 on database: errors<br> AzureDiagnostics<br> \| where Resource =~ "TENANTCRM"<br> \| where Category == "Errors"|  Language Reference  [SQL to Kusto query translation](https://docs.microsoft.com/en-us/azure/data-explorer/kusto/query/sqlcheatsheet) |
|On the results for each of the queries, change the to **Chart**<br><br>![](../../Images/dea1e46afaecbef9b0005c3e95b20144.png)<br> The chart Formatting is on the right.| // more specific queries <br> //Query get CPU usage <br> AzureDiagnostics <br>\| where Resource =~ "SQLHACKMI-WORWEGR7VULCU" and TimeGenerated \> ago(2h) //replace with your SQL MI Instance Name <br>\| where Category == "ResourceUsageStats"<br> \| project TimeGenerated, todecimal(avg_cpu_percent_s) <br>// visualize the resulset as a chart  ![](../../Images/dc5f8134b938a54b4b3f00262894ec55.png)<br><br>// Query get database Waits Stats <br>AzureDiagnostics<br> \| where Category == "QueryStoreWaitStatistics" <br>\| summarize Total_Wait_Ms = max(todouble(total_query_wait_time_ms_d)) by wait_category_s, DatabaseName_s <br>\| order by Total_Wait_Ms desc  <br><br> // visualize the resulset as a chart <br>![](../../Images/4dd51a5f1f7285ddafeb49aa9cad6d44.png)||
|Ask Copilot to explain a KQL query line by line. This is a good way to learn KQL.|![Copilot explains a KQL query](../../Images/Copilot_KQL_Explain.png)|**Prompt**: *"Explain this KQL query line by line and tell me what the wait categories mean."* (paste the wait statistics query)|

We’ve now seen how the various performance monitoring and diagnosis tools – GitHub Copilot, the Azure Portal, DMVs and the Query Store reports all revealed that the CPU was under pressure. The DMVs and Query Store reports also allowed us to drill-down to root cause and identify the worst offending query. Now we progress to tune the offending query to reduce the overall load on the Managed Instance CPUs and thereby improve the database and environment performance.

# 7. Fix the performance issue with GitHub Copilot

In this exercise you will leverage GitHub Copilot to mitigate the performance issue.

|**Narrative/Instructions**| **Screenshot**| **Notes**|
|:------------|:--------------|:---------|
|Ask Copilot for a recommendation to fix the most expensive stored procedure. Ask for an explanation **and** for the script, but tell Copilot not to execute it.|![Copilot recommends a fix](../../Images/Copilot_Recommend_Fix.png)|**Prompt**: *"Please suggest how to optimize the most CPU consuming stored procedure in TenantCRM. Explain the root cause and show me the scripts, but do not execute anything."*|
|GitHub Copilot identified the missing index and suggests to create the index. Review the explanation and the **CREATE INDEX** script.|![](../../Images/GithubCopilot_MissingIndex.png)|**Prompt**: *"What are the downsides of this index, for example for write performance and storage?"*|
|Insert the **CREATE INDEX** script into the query window and execute it.|||
|Check whether the problem is solved. Run the stored procedure again, or wait a few minutes and ask Copilot to compare the load before and after the change.|![CPU load after creating the index](../../Images/CPU_After_Index.png)|**Prompt**: *"I created the index. How can I verify that the CPU load and the duration of the stored procedure have improved? Please compare the Query Store data before and after the change."*|
|Optional: Ask Copilot to look for further issues in the database.|![Copilot finds further issues](../../Images/Copilot_Further_Issues.png)|**Prompt**: *"Are there other performance issues in TenantCRM that I should look at, for example other missing indexes, outdated statistics or queries with regressed plans?"*|

We have seen how GitHub Copilot can help us analyze and mitigate performance issues, and how the classic tools help us to verify the results.

# Prompt cheat sheet

| Goal | Example prompt |
|:-----|:---------------|
| Understand the context | *"Which database am I connected to and which tables does it contain?"* |
| Find the bottleneck | *"Please check for queries or stored procedures with the highest load in the TenantCRM database and suggest solutions for possible performance issues."* |
| Classify the problem | *"Is the problem a running problem (CPU) or a waiting problem? Please explain how you decided."* |
| Rank the offenders | *"Show me the top 5 stored procedures by total CPU time in TenantCRM."* |
| Explain a result | *"Explain the result of this query and what the avg_cpu_percent column tells me."* |
| Find the root cause | *"Why is this stored procedure so expensive? Please look at its code and its execution plan."* |
| Write KQL | *"Write a KQL query for the AzureDiagnostics table that shows the average CPU percentage of my SQL Managed Instance over the last 2 hours."* |
| Fix safely | *"Suggest how to optimize this stored procedure. Explain the root cause and show me the scripts, but do not execute anything."* |
| Verify the fix | *"How can I verify that the CPU load has improved after creating the index?"* |
