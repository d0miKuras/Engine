#pragma once
#include "Actor.h"
#include "Component.h"
class CircleColliderComponent : public Component
{
      public:
      CircleColliderComponent(Actor *actor) : Component(actor) {}
      inline void SetRadius(float radius) { mRadius = radius; }
      inline float GetRadius() const { return mRadius; }
      static bool Intersect(const CircleColliderComponent &a, const CircleColliderComponent &b);

      private:
	float mRadius;
};
