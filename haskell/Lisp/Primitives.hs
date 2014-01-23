module Lisp.Primitives where

-- TODO: add print-day, etc.

data Primitive = PCar
               | PCdr 
               | PCons
               | PIncr
               | PDecr
               | PIsZero 
               | PIsgt60
               | PIsgt24
               | PPrintSec
               | PPrintMin
               | PPrintHour
               deriving (Eq, Show)