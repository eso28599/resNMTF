#!/bin/bash
#PBS -N increasing_views_5b_nostab
#PBS -m a
#PBS -q medium
#PBS -t 1-100
#PBS -o ../Results/views/views_5b_nostab/logs/test_job.out
#PBS -e ../Results/views/views_5b_nostab/logs/test_job.err

export R_LIBS="/home/clustor2/ma/e/eso18/R/x86_64-pc-linux-gnu-library/4.3"
export sim_folder_name=Results/views/views_5b_nostab
export sim=views
export i=${PBS_ARRAYID}
export I=`echo $i | awk '{printf "%3.3d", $1}'`


cd ${PBS_O_WORKDIR}/../${sim_folder_name}/data
#mkdir $I
if [ ! -d "$I" ]; then
  mkdir $I
  cd $I
  for i in {2..5}
  do
    mkdir res_nmtf_$i
    mkdir nmtf_$i
    mkdir res_nmtf0_$i
    mkdir nmtf0_$i
  done
fi

#move back into original folde
cd ${PBS_O_WORKDIR}/..

#generate data
Rscript --vanilla data_gen.r  ${sim_folder_name} $I

# #now analyse in R
Rscript --vanilla methods_r_nostab.r  ${sim_folder_name} $I

#evaluate results in R
Rscript --vanilla eval.r  ${sim_folder_name} $I