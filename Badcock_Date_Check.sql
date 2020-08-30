SELECT TOP 1000 
Date
,PYDATE
,SUM(QTYONHAND) as CY_QtyOnHand
,SUM(pyqtyonhand) as PY_QtyOnHand
,SUM(materialcost)as CY_MaterialCost
,SUM(pymaterialcost) as PY_MaterialCost 

FROM FinancialAnalysis.la.InventoryDash a

--WHERE Date in ('2019-09-14','2018-09-14')

GROUP BY Date,PYDATE
ORDER BY Date desc
