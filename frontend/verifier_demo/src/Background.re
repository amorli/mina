module Styles = {
    open Css;
     let container = style([
    width(`vw(100.)),
    maxHeight(`vh(100.)),
    overflow(`hidden),
  ]);
  
  let curveRotation =
    keyframes([
      (0, [transform(rotate(`deg(0.)))]),
      (100, [transform(rotate(`deg(359.)))]),
    ]);
  
  let curve = style([
    position(`absolute),
    top(`calc(`sub, `percent(50.), `px(1000))),
    left(`calc(`sub, `percent(50.), `px(1000))),
     animation(curveRotation, ~duration=20000, ~iterationCount=`infinite, ~timingFunction=`linear), 
     height(`px(2000)),
  ]);
  
  let ring = style([
    position(`absolute),
    top(`calc(`sub, `percent(50.), `rem(16.0))),
    left(`calc(`sub, `percent(50.), `rem(16.0))),
     animation(curveRotation, ~duration=20000, ~iterationCount=`infinite, ~timingFunction=`linear), 
     height(`rem(32.)),
  ]);

};
 
 [@react.component]
let make = () => {
 <div className=Styles.container>
      <img className=Styles.curve src="/static/img/EllipticSeal.svg"> </img>
      <img className=Styles.ring src="/static/img/O1EstablishedRing.svg"> </img>
    </div>
}
