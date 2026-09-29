#!/bin/bash
echo "`date "+%m-%d-%Y %T"`: 开始运行脚本，路径: $1"
while read line;
do
   echo "`date "+%m-%d-%Y %T"`: $line";
done
