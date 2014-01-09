{-# LANGUAGE MultiParamTypeClasses, DoRec #-}

module Examples where

import Control.Applicative
import Control.Monad
import Circuit
import Data.List

-- temporary for testing
import Arithmetic
import Simulation

wordS = 24
addrS = 20 

processor :: (MemoryCircuit m s) => m [s]
processor = 
  do rec wireZero <- zero
         wireOne <- one
         controlSignals  <- control regBus
         regBus <- register (take 3 controlSignals) 
                            (head . drop 3 $ controlSignals)   
                            (take 3 . drop 4 $ controlSignals)
                            (regIn)
         regIn <-bigMux (head.drop 7 $ controlSignals) regBus gcOut  
         gcOut <- memorySystem (take 2 .drop 8 $ controlSignals)
                               regBus
         temporaries <- accessRAM 0 wordS ([],
                                           head.drop 10 $ controlSignals,
                                           [],
                                           regIn) 
     return controlSignals 


memorySystem :: (MemoryCircuit m s) => [s] -> [s] -> m [s]  
memorySystem = undefined 
 
bigMux :: (Circuit m s) => s -> [s] -> [s] -> m [s]
bigMux a b c = zipWithM (\y z -> mux3 (a,y,z)) b c

doubleMux :: (SequentialCircuit m s) => [s] -> s -> s -> s -> s -> m  s
doubleMux [a,b] x0 x1 x2 x3 =
    do  m1 <- mux3 (a,x0,x1)  
        m2 <- mux3 (a,x2,x3)
        mux3(b,m1,m2)

bigDoubleMux :: (SequentialCircuit m s) => [s] -> [s] -> [s] -> [s] -> [s] -> m [s]
bigDoubleMux [a,b] x0 x1 x2 x3 = 
   sequence $ zipWith4 (doubleMux [a,b]) x0 x1 x2 x3



orAll :: (SequentialCircuit m s) => [s] -> m s
--TODO : Check the code generated
-- /!\ we can improve with a dichotomy
orAll  [a] = do return a           
orAll (t:q) = do out <- t -||> orAll q
                 return out 
 
incrOrDecr :: (SequentialCircuit m s) => s -> [s] -> m [s]
incrOrDecr bitChoice (t:q) =
  do wireOne <- one
     wireZero <- zero
     fst <$> adder (wireZero, (wireOne,t):zip (repeat bitChoice) q)


ram :: (MemoryCircuit m s) => [s] -> s -> [s] -> [s] -> m [s]
ram addR flagW addW dataW = 
    accessRAM addrS wordS (addR,flagW,addW,dataW)


register :: (MemoryCircuit m s) => [s] -> s -> [s] -> [s] -> m [s]
register addR flagW addW dataW = 
    accessRAM 3 wordS (addR,flagW,addW,dataW) 

goTo :: (MemoryCircuit m s) => [s] -> m [s]
goTo ptr = 
    do z <- zero
       ram ptr z [] []    

control :: (MemoryCircuit m s) =>  [s] ->  m [s]
control regBus = 
  do rec wireZero<- zero
         internIncr <- incrOrDecr wireZero mpc 
         newMpc <- bigDoubleMux (take 2 controlSignals)
                                internIncr
                                (take romS . drop 2 $ controlSignals)
                                regBus
                                regBus
         mpc <- mapM delay newMpc 
         controlSignals <- accessROM romS microInstrS mpc 
     return $ drop 2 controlSignals 
  where romS=8
        microInstrS = 64

