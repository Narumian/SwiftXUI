//
//  BeatDetektor.swift
//  100VJ
//
//  Created by Narumi Inada on 2020/08/22.
//  Copyright © 2020 Narumi Inada. All rights reserved.
//


/*
 *  BeatDetektor.cpp
 *
 *  BeatDetektor - CubicFX Visualizer Beat Detection & Analysis Algorithm
 *
 * Copyright (c) 2009 Charles J. Cliffe.
 *
 * BeatDetektor is distributed under the terms of the MIT License.
 * http://opensource.org/licenses/MIT
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
 * FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS
 * IN THE SOFTWARE.
 
 
 24.Jan.2019
 */

import Foundation

public struct BeatDetektor2: Sendable {
    
    static let BD_DETECTION_RANGES : Int = 128
    static let BD_DETECTION_RATE : Float = 12.0
    static let BD_DETECTION_FACTOR : Float = 0.925
    static let BD_QUALITY_REWARD : Float = 7.0
    static let BD_QUALITY_STEP : Float = 0.1
    static let BD_QUALITY_TOLERANCE : Float = 0.96
    static let BD_QUALITY_DECAY : Float = 0.95
    static let BD_MINIMUM_CONTRIBUTIONS : Int = 6
   
    
    
    public var BPM_MAX : Float = 199.0
    public var BPM_MIN : Float = 100.0
    
    public var currentBPM : Float = 0.0
    
    private var lastTimer : Float = 0
    private var lastUpdate : Float = 0
    private var totalTime : Float = 0
    
    
    private var freqRange : [Float] = .init(repeating: 0.0, count: BeatDetektor2.BD_DETECTION_RANGES)
    private var maFreqRange :[Float] = .init(repeating: 0.0, count: BeatDetektor2.BD_DETECTION_RANGES)
    private var maaFreqRange :[Float] = .init(repeating: 0.0, count: BeatDetektor2.BD_DETECTION_RANGES)
    
    private var maBPMRange : [Float] = .init(repeating: 0.0, count: BeatDetektor2.BD_DETECTION_RANGES)
    private var maaBPMRange : [Float] = .init(repeating: 0.0, count: BeatDetektor2.BD_DETECTION_RANGES)
    
    private var detection : [Bool] = .init(repeating: false, count: BeatDetektor2.BD_DETECTION_RANGES)
    private var lastDetection : [Float] = .init(repeating: 0.0, count: BeatDetektor2.BD_DETECTION_RANGES)
    
    private var detectionQuality : [Float] = .init(repeating: 0.0, count: BeatDetektor2.BD_DETECTION_RANGES)
    
    private let rewardTolerances : [Float] = [0.001, 0.005, 0.01, 0.02, 0.04, 0.08, 0.10]
    private let rewardMutipliers : [Float] = [20.0, 10.0, 8.0, 1.0, 1.0/2.0, 1.0/4.0, 1.0/8.0]
    
    private var qualityAvg : Float = 1.0
    
    private var maQualityAvg : Float = 0.001
    private var maaQualityAvg : Float = 500.0
    private var maQualityTotal : Float = 1.0
    
    private var bpmOffset : Float = 0
    private var bpmPredict : Float = 0
    
    
    init(){
        reset()
    }
    
    
    public func getBPM() -> Float { currentBPM }
    
    public mutating func setBPMToleranceMin(_ min:Float, max:Float){
        BPM_MIN = min - 5
        BPM_MAX = max + 5
//        print("SetBPM", min, max)
    }

    
    
    public mutating func process(timerSeconds:Float, fftData:[Float]) {
        let dataCount = fftData.count
        
        if lastTimer == 0.0 { lastTimer = timerSeconds; return }
        if timerSeconds < lastTimer { reset(); return }
        
        lastUpdate = timerSeconds - lastTimer
        lastTimer = timerSeconds
        
        totalTime += lastUpdate
        
        let rangeStep = dataCount / Self.BD_DETECTION_RANGES
        let rangeStepF : Float = Float(rangeStep)
        
        var range : Int = 0
        
        let bpmFloor = 60.0 / BPM_MAX
        let bpmCeil = 60.0 / BPM_MIN
        
        for x in stride(from: 0, to: dataCount, by: rangeStep) {
            
            freqRange[range] = 0
            
            for i in x ..< x + rangeStep {
                let v = abs(fftData[i])
                freqRange[range] += v
            }
            
            freqRange[range] /= rangeStepF
            
            maFreqRange[range] -= (maFreqRange[range] - freqRange[range]) * lastUpdate * Self.BD_DETECTION_RATE
            
            maaFreqRange[range] -= (maaFreqRange[range] - maFreqRange[range]) * lastUpdate * Self.BD_DETECTION_RATE
            
            ///
            
            
            let det : Bool = (maFreqRange[range] * Self.BD_DETECTION_FACTOR) >= maaFreqRange[range]
            
            
            if maBPMRange[range] > bpmCeil { maBPMRange[range] = bpmCeil }
            if maBPMRange[range] < bpmFloor { maBPMRange[range] = bpmFloor }
            if maaBPMRange[range] > bpmCeil { maaBPMRange[range] = bpmCeil }
            if maaBPMRange[range] < bpmFloor { maaBPMRange[range] = bpmFloor }
            
            
            var rewarded : Bool = false
            
            if !detection[range] && det {
                var triggerGap = timerSeconds - lastDetection[range]
                
                if triggerGap < bpmCeil && triggerGap > bpmFloor {
                    
                    for i in 0 ..< rewardTolerances.count {
                        if abs(maBPMRange[range] - triggerGap) < maBPMRange[range] * rewardTolerances[i] {
                            detectionQuality[range] += Self.BD_QUALITY_REWARD * rewardMutipliers[i]
                            rewarded = true
                        }
                    }
                    
                    if rewarded {
                        lastDetection[range] = timerSeconds
                    }
                    
                }else if triggerGap >= bpmCeil {
                    triggerGap /= 2.0
                    
                    if triggerGap < bpmCeil && triggerGap > bpmFloor {
                        
                        for i in 0 ..< rewardTolerances.count {
                            detectionQuality[range] += Self.BD_QUALITY_REWARD * rewardMutipliers[i]
                            rewarded = true
                        }
                        
                        
                        
                    }
                    
                    if !rewarded { triggerGap *= 2.0 }
                    
                    lastDetection[range] = timerSeconds
                }
                
                ///
                var qmp : Float = (detectionQuality[range] / qualityAvg) * Self.BD_QUALITY_STEP
                
                if qmp > 1.0 { qmp = 1.0 }
                
                if rewarded {
                    maBPMRange[range] -= (maBPMRange[range] - triggerGap) * qmp
                    maaBPMRange[range] -= (maaBPMRange[range] - maBPMRange[range]) * qmp
                }
                else if triggerGap >= bpmFloor && triggerGap <= bpmCeil {
                    if detectionQuality[range] < qualityAvg * Self.BD_QUALITY_TOLERANCE && currentBPM != 0.0 {
                        maBPMRange[range] -= (maBPMRange[range] - triggerGap) * Self.BD_QUALITY_STEP
                        maaBPMRange[range] -= (maaBPMRange[range] - maBPMRange[range]) * Self.BD_QUALITY_STEP
                    }
                    detectionQuality[range] -= Self.BD_QUALITY_STEP
                }
                else if triggerGap >= bpmCeil {
                    if detectionQuality[range] < qualityAvg * Self.BD_QUALITY_TOLERANCE && currentBPM != 0.0 {
                        maBPMRange[range] -= (maBPMRange[range] - currentBPM) * 0.5
                        maaBPMRange[range] -= (maaBPMRange[range] - maBPMRange[range] * 0.5)
                    }
                    detectionQuality[range] -= Self.BD_QUALITY_REWARD * Self.BD_QUALITY_STEP
                }
                
            }
            
            if (!rewarded && timerSeconds - lastDetection[range] > bpmCeil) ||
                (det && abs(maBPMRange[range] - currentBPM) > bpmOffset) {
                detectionQuality[range] -= detectionQuality[range] * Self.BD_QUALITY_STEP * Self.BD_QUALITY_DECAY * lastUpdate
            }
            
            if detectionQuality[range] <= 0 { detectionQuality[range] = 0.001 }
            
            detection[range] = det
            
            range += 1
            
        }
        
        var qualityTotal : Float = 0.0
        
        var bpmTotal : Float = 0.0
        var bpmContributions : Int = 0
        
        qualityTotal = detectionQuality.reduce(0, +)
        
        qualityAvg = qualityTotal / Float(Self.BD_DETECTION_RANGES)
        
        
        maQualityAvg += (qualityAvg - maQualityAvg) * lastUpdate * Self.BD_DETECTION_RATE / 2.0
        maaQualityAvg += (maQualityAvg - maaQualityAvg) * lastUpdate
        maQualityTotal += (qualityTotal - maQualityTotal) * lastUpdate * Self.BD_DETECTION_RATE / 2.0
        
        maQualityAvg -= 0.98 * maQualityAvg * lastUpdate * 3.0
        
        if maQualityTotal <= 0.0 {maQualityTotal = 1.0}
        if maaQualityAvg <= 0.0 {maQualityAvg = 1.0}
        
        
        var avgBPMOffset : Float = 0.0
        var offsetTestBPM : Float = currentBPM
        
        var draft : [Int:Float] = [:]
        
    
        
        
        for x in 0 ..< Self.BD_DETECTION_RANGES {
            
            if detectionQuality[x] * Self.BD_QUALITY_TOLERANCE >= maQualityAvg,
                maaBPMRange[x] < bpmCeil && maaBPMRange[x] > bpmFloor {
                
                bpmTotal += maaBPMRange[x]
                var draftFloat = round(60.0 / maaBPMRange[x] * 1000.0)
                
                draftFloat = (abs(ceil(draftFloat)-(60.0/currentBPM)*1000.0)<(abs(floor(draftFloat)-(60.0/currentBPM)*1000.0))) ? ceil(draftFloat/10.0) : floor(draftFloat/10.0);
                
                let draftInt : Int = Int(draftFloat/10.0)
                
                draft[draftInt, default:0] += detectionQuality[x] / qualityAvg
                
                
                bpmContributions += 1
                
                if offsetTestBPM == 0.0 {
                    offsetTestBPM = maaBPMRange[x]
                }else{
                    avgBPMOffset += abs(offsetTestBPM - maaBPMRange[x])
                }
            }
        }
        
        let hasPrediction = bpmContributions >= Self.BD_MINIMUM_CONTRIBUTIONS
        
        guard hasPrediction else{return}
        
        
        
        var draftWinner : Int = 0
        var winMax : Float = 0
        
        draft.forEach { (key,value) in
            if value > winMax  {
                winMax = value
                draftWinner = key
            }
        }
        
        bpmPredict = 60.0 / (Float(draftWinner) / 10)
        
        avgBPMOffset /= Float(bpmContributions)
        bpmOffset = avgBPMOffset
        
        if currentBPM == 0 {
            currentBPM = bpmPredict
        }
        
        if currentBPM != 0 && bpmPredict != 0 { currentBPM -= (currentBPM - bpmPredict) * lastUpdate }
        if currentBPM < 0 { currentBPM = 0}
        
        
        
        
        
        
    }
    
    
    mutating func reset(resetFreq:Bool = true){
        
        let franges = Float(Self.BD_DETECTION_RANGES)
        for i in 0 ..< Self.BD_DETECTION_RANGES {
            
            let stp = 60.0 / (BPM_MAX - 5) - 60.0 / (BPM_MIN + 5)
            let v = 60.0 / (BPM_MIN + 5) + (stp * Float(i) / franges)
            
            maBPMRange[i] = v
            
            freqRange[i] = 0
            maFreqRange[i] = 0
            maaFreqRange[i] = 0
            
            lastDetection[i] = 0
            detectionQuality[i] = 0
            detection[i] = false
        }
        
        totalTime = 0
        maaQualityAvg = 500.0
        
        bpmOffset = 0
        lastUpdate = 0
        lastTimer = 0
        currentBPM = 0
        
    }
    
    
}
