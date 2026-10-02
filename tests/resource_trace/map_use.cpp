#include "dxmt_map_use.hpp"
#include <iostream>
#include <thread>
using dxmt::ResourceTelemetry;
int main(int argc,char **argv) {
  if(argc!=3) return 2;
  bool disabled=std::string(argv[2])=="disabled";
  if(disabled) unsetenv("DXMT_RESOURCE_LOG"); else setenv("DXMT_RESOURCE_LOG",argv[1],1);
  dxmt::MapUseTracker immediate, deferred(true);
  int resource = 0;
  if(std::string(argv[2])=="pairs") {
    immediate.begin(&resource,0,4);
    immediate.begin(&resource,1,5);
    std::this_thread::sleep_for(std::chrono::milliseconds(6));
    immediate.end(&resource,1,ResourceTelemetry::now());
    std::thread cross([&]{immediate.end(&resource,0,ResourceTelemetry::now());}); cross.join();
    deferred.begin(&resource,2,2);
    std::this_thread::sleep_for(std::chrono::milliseconds(4));
    deferred.end(&resource,2,ResourceTelemetry::now());
    immediate.end(&resource,99,ResourceTelemetry::now());
    immediate.begin(&resource,3,4); immediate.begin(&resource,3,4);
    immediate.end(&resource,3,ResourceTelemetry::now());
    // More colliding resources than the probe chain admits. No overwrite/UAF.
    for(uintptr_t i=1;i<=12;i++) immediate.begin((void*)(i*16384),0,4);
    for(uintptr_t i=1;i<=12;i++) immediate.end((void*)(i*16384),0,ResourceTelemetry::now());
  } else {
    constexpr unsigned count=100000;
    auto began=ResourceTelemetry::now();
    for(unsigned i=0;i<count;i++) {
      immediate.begin(&resource,0,4);
      if(!disabled) immediate.end(&resource,0,ResourceTelemetry::now());
    }
    std::cout << double(ResourceTelemetry::now()-began)/count << '\n';
  }
}
