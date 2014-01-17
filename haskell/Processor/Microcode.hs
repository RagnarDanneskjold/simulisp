module Processor.Microcode where

import Prelude hiding (return)

import Control.Arrow
import Data.Function

import Processor.MicroAssembler
import Processor.Parameters
import Data.List

selfEvaluating = [ Value ^= Expr,
                   dispatchReturn ]

label x = Label x Nothing


-- program start at address 0
boot = [ fetchCar registerNull Expr
       , dispatchEval ]

eval = [ (TNil     , selfEvaluating)
       , (TClosure , selfEvaluating)
       , (TList    , selfEvaluating)
       , (TNum     , selfEvaluating)
         
       , (TLocal   , lookupLocal ++
                     [ dispatchReturn ])
       , (TGlobal  , [ fetchCar Expr Value
                     , dispatchReturn ])
         
       , (TCond    , [ loadConditional Value
                     , condJump "condNotNil"
                     , fetchCdr Expr Expr
                     , label "condNotNil"
                     , fetchCar Expr Expr ])
         
       , (TProc    , [ moveToTemp Env
                     , allocConsWithTag Expr Value (tagBin TClosure)
                     , dispatchReturn ])

       , (TFirst   , saveCdrAndEvalCar RFirst)
       , (TNext    , push Args ++
                     saveCdrAndEvalCar RNext)
       , (TLast    , push Args ++
                     saveCdrAndEvalCar RLast)
         
       , (TApplyOne, saveCdrAndEvalCar RApplyOne)
       , (TLet     , saveCdrAndEvalCar RLet)
       , (TSequence, saveCdrAndEvalCar RSequence)
       ]
       ++
       [ (prim     , selfEvaluating)
       | prim <- [TCar, TCdr, TCons, TIncr, TDecr, TIsZero,
                  TIsgt60, TIsgt24, TPrintSec, TPrintMin, TPrintHour] ]

-- kind of a todo list...
registerNull = undefined
allocSingleton src dest = [ moveToTemp src
                          , allocCons registerNull dest ]
lookupLocal = undefined
getLastArg = fetchCar Args Value
fetchCarAndIncr = undefined
fetchCarAndDecr = undefined
fetchCarAndDecrRetrievingComp = undefined
fetchCarAndSubImmediate = undefined
pushWithReturn = undefined
allocConsWithReturn = undefined

dispatchEval   = Dispatch Expr  evalSuffix
dispatchApply  = Dispatch Expr  applySuffix
dispatchReturn = Dispatch Stack returnSuffix

apply = [ (t, allocSingleton Args Env ++
              [ Expr ^= Value
              , dispatchEval ])
        | t <- [TNil, TList, TNum, TLocal, TGlobal, TCond, TProc,
                TFirst, TNext, TLast, TApplyOne, TLet, TSequence]
        ]
        ++
        map (second (++ [dispatchReturn]))
        [ (TCar      , [ getLastArg
                       , fetchCar Value Value ])
        , (TCdr      , [ getLastArg
                       , fetchCdr Value Value ])
        , (TCons     , [ getLastArg
                       , moveToTemp Value
                       , fetchCdr Args Value
                       , fetchCar Value Value
                       , allocCons Value Value ])
        , (TIncr     , [ fetchCarAndIncr Args Value ])
        , (TDecr     , [ fetchCarAndDecr Args Value ])
        , (TIsZero   , [ fetchCarAndDecrRetrievingComp Args Value ])
        , (TIsgt60   , [ fetchCarAndSubImmediate Args Value 60 ])
        , (TIsgt24   , [ fetchCarAndSubImmediate Args Value 24 ])
        , (TPrintSec , undefined)
        , (TPrintMin , undefined)
        , (TPrintHour, undefined)
        ]

popToReg reg = [ fetchCar Stack reg
               , fetchCdr Stack Stack ]
standardRestore = popToReg Expr ++
                  popToReg Env

return = [ (RFirst    , standardRestore ++
                        allocSingleton Value Args ++
                        [ dispatchEval ])
           
         , (RNext     , standardRestore ++
                        popToReg Args ++
                        [ moveToTemp Value
                        , allocCons Args Args
                        , dispatchEval ])
           
         , (RLast     , standardRestore ++
                        popToReg Args ++
                        [ moveToTemp Value
                        , allocCons Args Args 
                        , moveToTemp Args
                        , allocConsWithReturn Stack Stack RApply
                        , dispatchEval ])
           
         , (RApplyOne , standardRestore ++
                        allocSingleton Value Args ++
                        pushWithReturn Args RApply ++
                        [ moveToTemp Args
                        , allocConsWithReturn Stack Stack RApply
                        , dispatchEval ])
           
         , (RLet      , standardRestore ++
                        allocSingleton Value Value ++
                        [ moveToTemp Value
                        , allocCons Env Env
                        , dispatchEval ])

         , (RSequence , standardRestore ++
                        [ dispatchEval ])

         , (RApply    , popToReg Args ++
                        [ dispatchApply ])
         ]

microprogram :: [Instruction]
microprogram = boot ++ eval' ++ apply' ++ return'
  where eval'   = concat [ Label ("E" ++ show tag) (Just $ evalAddr tag) : code
                         | (tag, code) <- sortBy (compare `on` (evalAddr . fst)) eval ]
        apply'  = concat [ Label ("A" ++ show tag) (Just $ applyAddr tag) : code
                         | (tag, code) <- sortBy (compare `on` (applyAddr . fst)) apply ]
        return' = concat [ Label (show tag) (Just $ returnAddr tag) : code
                         | (tag, code) <- sortBy (compare `on` (returnAddr . fst)) return ]
        evalAddr   = addressOfTag evalSuffix   . tagNum
        applyAddr  = addressOfTag applySuffix  . tagNum
        returnAddr = addressOfTag returnSuffix . returnNum
        smallBlockSize = 2^(microAddrS - tagS - 2)
        bigBlockSize   = 2^(microAddrS - 2)
        addressOfTag [b0,b1] i = j*bigBlockSize + i*smallBlockSize
          where j = 2*b1' + b0'
                b1' | b1 = 1
                    | otherwise = 0
                b0' | b0 = 1
                    | otherwise = 0
        


         

push :: Reg -> [Instruction]                 
push reg = [ moveToTemp reg
           , allocCons Stack Stack]

-- pushWithReturn :: [Bool] -> Reg -> [Instruction]
-- pushWithReturn retTag reg = [moveToTemp reg,allocConsWithTag Stack Stack retTag]

walkOnList = undefined

saveCdrAndEvalCar returnTag = push Env ++
                              [ fetchCdrTemp Expr
                              , allocConsWithReturn Stack Stack returnTag
                              , fetchCar Expr Expr
                              , dispatchEval ] 
                                
