DECLARE @date  date
DECLARE @orderstart date
DECLARE @orderend date
SET @date = GETDATE()-1
SET @orderstart = '2019-05-01'
SET @orderend = '2019-11-30';

--*************************************************************************************************************************************************************
--This CTE pulls all Online Orders
WITH WebOrders as (SELECT o.OrderID, Code , o.OrderDate,o.CustomerID
FROM BadcockDW.storis.DW_Order o
LEFT JOIN BadcockDW.storis.DW_OrderSource os ON o.OrderSourceID = os.OrderSourceID
WHERE  o.TransCodeID IN (0,1,3,7,20,30,31,37,50) 
AND code in ('MWEB', 'ECOMM') 
AND o.OrderDate >= @orderstart

) -- Date is a safety to help limit query time as Ecommerce started in May 
--*************************************************************************************************************************************************************
-- This CTE builds a table that compares items on the product id level that were written with what was completed.
-- Items that were originally written online appear UpdateBy_StaffID ='WEBDE5'
-- When this table is joined to the main query 
-- if a warranty is added by a Salesperson the that product ID salesperson would reflect that not ZWEB and the whole order would would change updateBy_StaffID

,Modified as (SELECT DISTINCT
CASE WHEN d.ProductID = b.ProductID THEN 'NO' ELSE 'YES' END AS 'Modified',

ISNULL(b.writtenflag,d.writtenflag) as WrittenFlag --IF product was not completed will show written
,ISNULL(d.Base_OrderID,b.Base_OrderID) as OrderID
,ISNULL(d.ProductID,b.ProductID) as ProductID
,CASE WHEN b.TransDate <= @date --Date issue was fixed in storis
		and b.SalespersonID <>'ZWEB' --Completed Salesperson
		and d.SalespersonID = 'ZWEB' --Written Salesperson
		and b.code = 'ECOMM' THEN 'MWEB' ELSE ISNULL(b.Code,d.Code) END as Code -- FIX ERRORS MADE by STORIS issue


 FROM (   -- ORIGNAL WEB ORDER ITEMS
SELECT bta.*,w.Code
FROM [BadcockDW].[storis].BtaData bta
INNER JOIN WebOrders w ON bta.Base_OrderID = w.OrderID
where  UpdateBy_StaffID ='WEBDE5'	--This column is used instead of salespersonid because an order can be updated and the salesperson will not change from 'ZWEB' :See sql query ZWEB Test as an example.
									-- An online order is not edited if the UpdateBy_StaffID ='WEBDE5' 
AND bta.TransCodeID IN (0,1,3,7,20,30,31,37,50) AND code in ('MWEB', 'ECOMM') 
) d
 FULL JOIN (-- INVOICED ITEMS
  SELECT    bta.*,w.Code
  FROM [BadcockDW].[storis].BtaData bta
  INNER JOIN WebOrders w ON bta.Base_OrderID = w.OrderID
  WHERE  WrittenFlag = 0
  AND bta.TransCodeID IN (0,1,3,7,20,30,31,37,50) AND code in ('MWEB', 'ECOMM') ) b 
   
  ON d.Base_OrderID = b.Base_OrderID AND d.ProductID = b.ProductID)
--*************************************************************************************************************************************************************
, NewCustomers as (
SELECT 
i.customerid, min(i.InvoiceDate) as MinInvoiceDate

FROM  BadcockDW.storis.DW_Invoice i 
INNER JOIN (SELECT o.OrderID, Code , o.InvoiceDate,o.CustomerID
FROM BadcockDW.storis.DW_Invoice o
INNER JOIN BadcockDW.storis.DW_OrderSource os ON o.OrderSourceID = os.OrderSourceID
WHERE  o.TransCodeID IN (0,1,3,7,20,30,31,37,50) AND code in ('MWEB', 'ECOMM') AND o.InvoiceDate > @orderstart ) w on i.CustomerID = w.customerid
GROUP BY  i.customerid)

,allorders as (SELECT DISTINCT w.Customerid,CASE WHEN right(i.OrderID,1) = 'e' THEN   LEFT(i.OrderID,10) ELSE i.OrderID END AS OrderID,i.InvoiceDate,os.Code ,i.WrittenTime
			FROM WebOrders w 
			JOIN BadcockDW.storis.DW_Order i					ON w.CustomerID = i.CustomerID
			LEFT JOIN BadcockDW.storis.DW_OrderSource os	ON i.OrderSourceID = os.OrderSourceID
			WHERE i.InvoiceDate Between @orderstart and @orderend
			AND i.TransCodeID in (0,1) --to only look at subsequent purchases (exclude exchanges and returns)
			)
--************************************************************************************************************************************************************
--************************************************************************************************************************************************************
--THIS Section is to add MIN(InvoiceDate) per customer to calculate New Customer. Add Family, and product type id and description. 

,datat as( --made main query CTE so could classify the whole order and eliminate partition by on OrderCount

SELECT 
a.OrderID
,a.OrderDate
,a.InvoiceDate
--,a.VoidedDate
,a.TransCodeID
,a.CustomerID
,a.ProductID
,pr.family
,a.WrittenFlag
,ISNULL(m.code,a.code) as Code -- To Overwrite Storis Error
--,a.Cancelled
,a.NetUnits,a.NetSales
		,CASE WHEN a.[CustomerID] =LAG(a.[CustomerID]) OVER (ORDER BY a.customerid,a.WrittenFlag, a.[invoicedate]) then 0 
							ELSE 1
							END as CustomerCount -- Only counting customers first Online Invoice
							
		,CASE WHEN a.[OrderID] =LAG(a.[OrderID]) OVER (ORDER BY a.orderid,a.WrittenFlag, a.[invoicedate],a.transcodeid) then 0 -- took written flag partition out to count FinalOrderType 
							ELSE 1
							END as OrderCount
,pr.description
,m.Modified as ModifiedItem -- Due to the join and summation of the ISNULLs in the CTE this only evaluates completed orders. Null means written only
--,nc.MinInvoiceDate			-- Used to calculate First Invoiced Order
,CASE WHEN a.InvoiceDate = nc.MinInvoiceDate THEN 'NEW' 
	WHEN a.InvoiceDate > nc.MinInvoiceDate THEN 'Existing' END AS NewCustomer
--,pr.ProductTypeID
,CASE WHEN s.Sub IN ( 'ECOMM','MWEB') THEN 'Online' WHEN s.Sub = 'DEF' THEN 'Store' END as Sub
,CASE WHEN a.WrittenFlag = 1 AND a.TransCodeID = 0 AND a.Cancelled IS NULL THEN 'Written'
	WHEN a.WrittenFlag = 1 AND a.Cancelled = 'Cancelled' THEN 'Cancelled'
	WHEN a.WrittenFlag = 0 and a.TransCodeID = 0 THEN 'Completed'
	WHEN a.WrittenFlag = 0 and a.TransCodeID = 7 THEN 'Exchange'--when summing netsales & netunits only
	WHEN a.WrittenFlag = 0 and a.TransCodeID IN (30,31,37,50) THEN 'Return' 
	ELSE 'NOT COUNTED' -- To Filter OUT Written Flag duplication when summing netunits and netsales in the report (not count written exchanges or returns)
	END AS OrderType
FROM (
--START SUB QUERY ******************************************************************************************************************************************************************

		SELECT 
		CASE WHEN right(o.OrderID,1) = 'e' THEN   LEFT(o.OrderID,10) ELSE o.OrderID END AS OrderID --No BaseOrderID
		,o.OrderDate
		,DATENAME(MONTH,o.OrderDate) as OrderMonth
		,DATEPART(year,o.OrderDate) as OrderYear
		,o.InvoiceDate
		,DATENAME(MONTH,o.InvoiceDate) as InvoiceMonth
		,DATEPART(year,o.InvoiceDate) as InvoiceYear
		,o.VoidedDate
		,o.TransCodeID
		,o.CustomerID
		,bta.ProductID
		,bta.Family
		,bta.WrittenFlag
		,Code

		,CASE WHEN  bta.UpdateTypeID IN ('V','D')THEN 'Cancelled' ELSE NULL END as Cancelled -- 
		,SUM(bta.NetUnits) as netunits
		,SUM(bta.NetSales) as netsales

		FROM [BadcockDW].[storis].[DW_Order] o				--USING Order table as base to look at everything not just invoiced
		INNER JOIN [BadcockDW].[storis].[DW_OrderSource] os -- Determines ECOMM or MWEB
			ON os.OrderSourceID = o.OrderSourceID    
		LEFT JOIN BadcockDW.storis.BtaData bta				
			ON o.OrderID= bta.Base_OrderID AND o.CustomerID = bta.CustomerID 
		LEFT JOIN (
			SELECT Customerid, MIN(OrderDate) as MinOrderDate 
					FROM BadcockDW.storis.DW_Order 
					GROUP BY CustomerID) n					ON o.CustomerID = n.CustomerID

		WHERE KitStatus <>'M' 
		AND o.TransCodeID IN (0,1,3,7,20,30,31,37,50) 
		AND code in ('MWEB', 'ECOMM') 
		AND o.OrderDate Between @orderstart and @orderend
		
		GROUP BY  o.OrderID,o.OrderDate,o.TransCodeID,o.CustomerID,bta.ProductID,bta.Family,bta.WrittenFlag,Code,UpdateTypeID,o.InvoiceDate,o.VoidedDate
		) a 
--END SUB QUERY ******************************************************************************************************************************************************************


LEFT JOIN Modified m ON a.OrderID = m.OrderID AND a.ProductID = m.ProductID AND a.WrittenFlag = m.WrittenFlag  -- Classify modified items
 INNER JOIN (SELECT p.productid, f.family,p.Description,p.producttypeid
				FROM [BadcockDW].[storis].[Product] p
				INNER JOIN BadcockDW.storis.Groups AS g 
				ON p.[GroupID]=g.groupid
				INNER JOIN BadcockDW.storis.Category AS f
				ON g.[CategoryID]=f.[CategoryID] WHERE p.KitStatus <>'M' )pr		ON a.ProductID = pr.ProductID -- to pull product family 
LEFT JOIN NewCustomers nc ON a.customerid = nc.customerid 

LEFT JOIN (
SELECT DISTINCT *
,CASE WHEN code in ('MWEB', 'ECOMM') then 'Online' WHEN code in ('DEF') THEN 'Store' end as online   

,CASE WHEN CustomerID =LAG(CustomerID) OVER ( ORDER BY customerid,writtentime desc) then lag(InvoiceDate) over ( partition by customerid ORDER BY customerid,writtentime desc )
							ELSE NULL
							END as SubDate
,CASE WHEN CustomerID =LAG(CustomerID) OVER ( ORDER BY customerid,writtentime desc) then lag(code) over ( partition by customerid ORDER BY customerid,writtentime desc)
							ELSE NULL
							END as Sub

		 FROM allorders a) s 
			ON a.OrderID = s.OrderID 


WHERE  OrderDate Between @orderstart and @orderend 
		AND pr.producttypeid <> 3
		--AND a.OrderID = '744J764286' --WHERE TO TROUBLE SHOOT

GROUP BY 
a.OrderID,a.OrderDate,a.InvoiceDate,a.VoidedDate,a.TransCodeID,a.CustomerID,a.ProductID,pr.Family,a.WrittenFlag,a.Cancelled,a.netunits,a.netsales
,pr.Description,m.Modified,nc.MinInvoiceDate,ProductTypeID,Sub,a.code,m.Code

)
--************************************************************************************************************************************************************
, ordertype as( --Combines all line items for the order
SELECT DISTINCT orderid
,case when ordertype = 'Written' then 1 ELSE 0 END AS Written
,case when ordertype = 'Cancelled' then 1 ELSE 0 END AS Cancelled
,case when ordertype = 'Completed' then 1 ELSE 0 END AS Completed
,case when ordertype = 'Exchange' then 1 ELSE 0 END AS Exchange
,case when ordertype = 'Return' then 1 ELSE 0 END AS RET 

 from datat  )
--************************************************************************************************************************************************************
,orderclass as( --Classifies the whole order based on ordertype as an order can have multiple types. For example line items in an order can be completed and cancelled but overall only some items are cancelled 
				--making the whole order complete.
SELECT orderid 
,CASE WHEN SUM(Completed) =1 then 'Completed'
	WHEN SUM(Exchange) = 1 then 'Exchange'
	WHEN SUM(Cancelled) = 1 AND SUM(Completed) =0 then 'Cancelled'
	WHEN SUM(Written) = 1 AND SUM(Completed) =0 AND SUM(Cancelled) = 0 then 'Written'
	WHEN SUM(RET)= 1 THEN 'Return' ELSE 'NOT COUNTED' END AS FinalOrderType
	
FROM ordertype
GROUP BY OrderID)
--************************************************************************************************************************************************************

Select d.*,oc.FinalOrderType from datat d
LEFT JOIN orderclass oc on  d.OrderID = oc.OrderID
WHERE InvoiceDate Between @orderstart and @orderend
OR InvoiceDate IS NULL
ORDER BY OrderID,WrittenFlag,ProductID




