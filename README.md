This PowerShell script is designed to calculate the cost of retiring resources in Azure.

## Requirements
**You need to be at least a Reader in order to export the data and invoke the Cost Management API used to calculate cost of resources being retired.**

## Usage
1. Go to Azure Advisor and open the workbook called Service Retirement (preview):

![image](https://github.com/formicalab/Get-CostOfRetiringResources/assets/12999635/5ca2056d-3acf-4e5c-baf2-65c06da8ee3a)


2. Select view Impacted Services:

![image](https://github.com/formicalab/Get-CostOfRetiringResources/assets/12999635/80e4214b-a5f9-4aec-bce0-79fba20a9e22)


3. Export to Excel:

![image](https://github.com/formicalab/Get-CostOfRetiringResources/assets/12999635/4f344608-3a13-437c-b4d9-a75c3cade2ce)


4. Open the file in Excel and export to CSV. **Note: the script currently uses ';' as field separator**
5. Execute the script in a PowerShell 7 session, with the Az module installed and logged to Azure.

```
.\get-costofretiringresources.ps1 -billingPeriod <YYYYMM> -ResourceIdFile <exported file> [-endDate YYYY-MM-DD]
```

For example:

```
.\get-costofretiringresources.ps1 -billingPeriod 202405 -ResourceIdFile .\export_data.csv -endDate 2024-08-31
```

6. The script imports the data, sort them by retirement date and retiring feature, leaving out resources that, in theory, have been _already_ retired..
7. For the remaining resources, to be retired in any future date from today (or: from today to -endDate, if specified), it uses the Azure Cost Management API to extract the cost that the resource had in the specified billing period.
8. The total costs are then shown at the end of execution.

## References

Cost Management API:  
https://learn.microsoft.com/en-us/rest/api/cost-management/query/usage?view=rest-cost-management-2023-11-01&tabs=HTTP
```
https://management.azure.com/subscriptions/${subscriptionId}/resourceGroups/${resourceGroup}/providers/Microsoft.CostManagement/query?api-version=2023-11-01"
```
